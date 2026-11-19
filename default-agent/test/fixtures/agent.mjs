// The real agent, with the synthetic provider added.
import { runAgent } from '../../src/agent.mjs';
import { synthetic } from './synthetic.mjs';

await runAgent({ extraProviders: [synthetic] });
