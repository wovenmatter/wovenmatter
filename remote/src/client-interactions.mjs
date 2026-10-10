const invalid=()=>new Error('Unsupported native interaction schema.')
const object=value=>value&&typeof value==='object'&&!Array.isArray(value)
const only=(value,keys)=>Object.keys(value).every(key=>keys.includes(key))
const bounded=value=>typeof value==='string'&&value.length<=262144
const choice=(id,label=id)=>({id,label})
function choices(field,multiple=false) {
  if(field.enum&&field[multiple?'anyOf':'oneOf'])throw invalid()
  const source=field.enum??field[multiple?'anyOf':'oneOf']
  if(!Array.isArray(source)||!source.length||source.length>256)throw invalid()
  if(field.enumNames&&(!Array.isArray(field.enumNames)||field.enumNames.length!==source.length||field.enumNames.some(value=>!bounded(value))))throw invalid()
  const result=source.map((value,index)=>typeof value==='string'?choice(value,field.enumNames?.[index]??value):
    object(value)&&only(value,['const','title','description','_meta'])&&bounded(value.const)?choice(value.const,value.title??value.const):null)
  if(result.some(value=>!value)||new Set(result.map(value=>value.id)).size!==result.length)throw invalid()
  return result
}
export function clientInteraction(message) {
  const p=message.params??{}
  if(message.method==='cursor/create_plan') {
    if(!bounded(p.plan)||typeof p.toolCallId!=='string'||!Array.isArray(p.todos))throw invalid()
    return {kind:'approval',title:p.name??'Proposed plan',detail:p.plan,options:[choice('accept','Accept plan'),choice('reject','Decline')],questions:[]}
  }
  if(message.method==='cursor/ask_question') {
    if(typeof p.toolCallId!=='string'||!Array.isArray(p.questions)||!p.questions.length||p.questions.length>64)throw invalid()
    const questions=p.questions.map(item=>{
      if(!bounded(item.id)||!bounded(item.prompt)||!Array.isArray(item.options)||item.options.length>256||item.options.some(option=>!bounded(option.id)||!bounded(option.label)))throw invalid()
      return {id:item.id,prompt:item.prompt,options:item.options.length?item.options:[choice('ok','OK')],allowsMultiple:item.allowMultiple===true,allowsFreeText:false,required:true}
    })
    if(new Set(questions.map(item=>item.id)).size!==questions.length)throw invalid()
    return {kind:'question',title:p.title??'Agent question',options:[],questions}
  }
  if(message.method!=='elicitation/create')return null
  const schema=p.requestedSchema
  if(p.mode!=='form'||!bounded(p.message)||!object(schema)||schema.type!=='object'||!object(schema.properties)
    ||Object.keys(schema.properties).length>64||!only(schema,['type','title','description','properties','required','additionalProperties','$schema','_meta'])
    ||(schema.additionalProperties!=null&&schema.additionalProperties!==false))throw invalid()
  const required=schema.required??[]
  if(!Array.isArray(required)||new Set(required).size!==required.length||required.some(id=>typeof id!=='string'||!Object.hasOwn(schema.properties,id)))throw invalid()
  const questions=Object.entries(schema.properties).sort(([a],[b])=>a.localeCompare(b)).map(([id,field])=>{
    if(!object(field))throw invalid()
    const common=['type','title','description','default','_meta']
    let options=[],allowed=[],multi=false,free=false
    if(field.type==='string') {
      allowed=['minLength','maxLength','format','enum','enumNames','oneOf']
      if(field.format==='password'||field._meta?.secret===true)throw invalid()
      if(field.enum||field.oneOf)options=choices(field);else free=true
      if(options.length&&(field.minLength!=null||field.maxLength!=null))throw invalid()
    } else if(field.type==='array') {
      allowed=['items','minItems','maxItems'];multi=true
      if(!object(field.items)||(field.items.type!=null&&field.items.type!=='string')||!only(field.items,['type','enum','enumNames','anyOf','_meta']))throw invalid()
      options=choices(field.items,true)
    } else if(field.type==='boolean')options=[choice('true','Yes'),choice('false','No')]
    else if(['number','integer'].includes(field.type)){allowed=['minimum','maximum'];free=true}
    else throw invalid()
    if(!only(field,[...common,...allowed]))throw invalid()
    for(const key of ['minLength','maxLength','minItems','maxItems'])if(field[key]!=null&&(!Number.isSafeInteger(field[key])||field[key]<0))throw invalid()
    for(const key of ['minimum','maximum'])if(field[key]!=null&&(typeof field[key]!=='number'||!Number.isFinite(field[key])))throw invalid()
    if(field.minimum>field.maximum||field.minLength>field.maxLength||field.minItems>field.maxItems)throw invalid()
    return {id,prompt:field.title??id,options,allowsMultiple:multi,allowsFreeText:free,required:required.includes(id)}
  })
  return {kind:'question',title:p.message,options:[],questions}
}
export function clientInteractionResponse(message,response) {
  const view=clientInteraction(message)
  if(!view)throw invalid()
  if(message.method==='cursor/create_plan')return {accepted:!response.cancelled&&response.optionID==='accept'}
  if(response.cancelled)return message.method==='elicitation/create'?{action:'cancel'}:{answers:{}}
  const answers=response.answers??{}
  if(!object(answers)||Object.keys(answers).some(id=>!view.questions.some(question=>question.id===id)))throw invalid()
  const result={}
  for(const question of view.questions) {
    const selected=answers[question.id]??[]
    if(!Array.isArray(selected)||selected.some(value=>!bounded(value))||(!question.allowsMultiple&&selected.length>1)||new Set(selected).size!==selected.length)throw invalid()
    if(!selected.length){if(question.required)throw invalid();continue}
    if(!question.allowsFreeText&&selected.some(value=>!question.options.some(option=>option.id===value)))throw invalid()
    if(message.method==='cursor/ask_question'){result[question.id]=question.allowsMultiple?selected:selected[0];continue}
    const field=message.params.requestedSchema.properties[question.id],value=selected[0]
    if(field.type==='array') {
      if(selected.length<(field.minItems??0)||selected.length>(field.maxItems??Infinity))throw invalid()
      result[question.id]=selected
    } else if(['number','integer'].includes(field.type)) {
      if(!value.trim())throw invalid()
      const number=Number(value)
      if(!Number.isFinite(number)||(field.type==='integer'&&!Number.isInteger(number))||number<(field.minimum??-Infinity)||number>(field.maximum??Infinity))throw invalid()
      result[question.id]=number
    } else if(field.type==='boolean')result[question.id]=value==='true'
    else {
      const length=Array.from(value).length
      if(length<(field.minLength??0)||length>(field.maxLength??Infinity))throw invalid()
      result[question.id]=value
    }
  }
  return message.method==='elicitation/create'?{action:'accept',content:result}:{answers:result}
}
