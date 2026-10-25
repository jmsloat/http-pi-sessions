// Test-only provider: real Pi agent loop + real Gentle tools, no remote model.
// Resolve this file from a directory with Pi's npm dependencies installed.
import {createAssistantMessageEventStream} from '@earendil-works/pi-ai';
export default function(pi: any) {
  let step = 0;
  pi.registerProvider('desk-test', {
    baseUrl: 'http://unused.invalid', apiKey: 'test-only', api: 'desk-test-api',
    models: ['deterministic','deterministic-reasoning'].map(id=>({id,name:id,reasoning:id.endsWith('reasoning'),input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:32000,maxTokens:2048})),
    streamSimple(model: any, _context: any, options: any) {
      const stream = createAssistantMessageEventStream();
      const thisStep = step++ % 4;
      const tasks = [
        {id:1,title:'Use the real Gentle Todo tool',status:thisStep===2?'done':'in_progress'},
        {id:2,title:'Answer the real Gentle question',status:thisStep===2?'done':'pending'},
        {id:3,title:'Restore the session after reconnect',status:thisStep===2?'done':'pending'}
      ];
      const calls: any[] = thisStep === 0 || thisStep === 2
        ? [{type:'toolCall',id:`todo-${step}`,name:'todo',arguments:{action:'write',tasks}}]
        : thisStep === 1
          ? [{type:'toolCall',id:`question-${step}`,name:'ask_user_question',arguments:{questions:[{header:'Prototype',question:'Can you see the real Gentle Todo list?',options:[{label:'Yes',description:'The three tasks are visible.'},{label:'No',description:'The panel is missing or empty.'}],multiSelect:false}]}}]
          : [];
      const output: any = {role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'pending',timestamp:Date.now()};
      (async () => {
        stream.push({type:'start',partial:output});
        if(calls.length) {
          output.content=calls; output.stopReason='toolUse';
          stream.push({type:'toolcall_start',contentIndex:0,partial:output});
          stream.push({type:'toolcall_end',contentIndex:0,toolCall:calls[0],partial:output});
        } else {
          output.content=[{type:'text',text:''}]; stream.push({type:'text_start',contentIndex:0,partial:output});
          for(const word of 'The real Pi runtime executed Gentle Todo and its question tool. This response comes from a deterministic test provider, not a language model.'.split(' ')) {
            await new Promise(r=>setTimeout(r,30));
            if(options?.signal?.aborted) {output.stopReason='aborted';stream.push({type:'error',reason:'aborted',error:output});stream.end();return;}
            output.content[0].text+=word+' ';
            stream.push({type:'text_delta',contentIndex:0,delta:word+' ',partial:output});
          }
          output.stopReason='stop';
        }
        stream.push({type:'done',reason:output.stopReason,message:output});stream.end();
      })().catch(error=>{output.stopReason='error';output.errorMessage=String(error);stream.push({type:'error',reason:'error',error:output});stream.end();});
      return stream;
    }
  });
}
