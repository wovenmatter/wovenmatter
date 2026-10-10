import test from 'node:test'
import assert from 'node:assert/strict'
import { clientInteraction,clientInteractionResponse } from '../src/client-interactions.mjs'
const form=properties=>({method:'elicitation/create',params:{mode:'form',message:'Choose',requestedSchema:{type:'object',properties,required:['count'],additionalProperties:false}}})
test('native forms preserve required fields, typed booleans/numbers and choice validation',()=>{
  const value=form({count:{type:'integer',minimum:1,maximum:3},enabled:{type:'boolean'},flavors:{type:'array',items:{enum:['a','b']},maxItems:1},note:{type:'string',maxLength:2}})
  assert.deepEqual(clientInteraction(value).questions.map(q=>[q.id,q.required]),[['count',true],['enabled',false],['flavors',false],['note',false]])
  assert.deepEqual(clientInteractionResponse(value,{answers:{count:['2'],enabled:['false'],flavors:['a'],note:['🙂🙂']}}),{action:'accept',content:{count:2,enabled:false,flavors:['a'],note:'🙂🙂'}})
  for(const answers of [{count:['0']},{count:['1.5']},{count:['2'],enabled:['perhaps']},{count:['2'],flavors:['a','b']},{note:['a']}])assert.throws(()=>clientInteractionResponse(value,{answers}))
})
test('unsupported and secret-bearing forms are rejected before presentation',()=>{
  for(const field of [{type:'string',format:'password'},{type:'string',pattern:'.*'},{type:'object',properties:{}},{type:'string',_meta:{secret:true}}])assert.throws(()=>clientInteraction(form({count:field})))
  assert.throws(()=>clientInteraction({...form({count:{type:'string'}}),params:{mode:'url',url:'https://example.test/login'}}))
})
test('Cursor questions and plan decisions map to native wire responses',()=>{
  const question={method:'cursor/ask_question',params:{toolCallId:'tool',questions:[{id:'choose',prompt:'Pick',options:[{id:'a',label:'A'},{id:'b',label:'B'}],allowMultiple:true}]}}
  assert.deepEqual(clientInteractionResponse(question,{answers:{choose:['a','b']}}),{answers:{choose:['a','b']}})
  assert.deepEqual(clientInteractionResponse(question,{cancelled:true}),{answers:{}})
  assert.throws(()=>clientInteractionResponse(question,{answers:{choose:['c']}}))
  const plan={method:'cursor/create_plan',params:{toolCallId:'plan',plan:'# Steps',todos:[]}}
  assert.deepEqual(clientInteractionResponse(plan,{optionID:'accept'}),{accepted:true})
  assert.deepEqual(clientInteractionResponse(plan,{cancelled:true}),{accepted:false})
})
