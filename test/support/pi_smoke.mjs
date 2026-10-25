// Run against installed Pi + gentle-pi. Uses a deterministic provider, not API credentials.
import {spawn} from 'node:child_process';
import {mkdtempSync,copyFileSync,writeFileSync,readFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import assert from 'node:assert/strict';
const runtime = resolve(process.env.PI_TEST_RUNTIME || '../runtime-check');
const temp = mkdtempSync(join(tmpdir(),'session-desk-pi-'));
const provider=join(runtime,'desk-test-provider.ts');
copyFileSync(new URL('./deterministic-provider.ts',import.meta.url),provider);
const pi=join(runtime,'node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js');
const gentle=join(runtime,'node_modules/gentle-pi/extensions');
const session=join(temp,'session.jsonl');
const args=[pi,'--mode','rpc','--session',session,'--no-extensions','--no-skills','--no-prompt-templates',
  '-e',join(gentle,'gentle-todo.ts'),'-e',join(gentle,'ask-user-question.ts'),'-e',provider,'--provider','desk-test','--model','deterministic'];
let events=[],buffer='',errors='',ready=false;
const child=spawn(process.execPath,args,{cwd:temp,env:{...process.env,PI_CODING_AGENT_DIR:join(temp,'home'),GENTLE_SHELL_INTERACTIVE_HOST:'1'},stdio:['pipe','pipe','pipe']});
const send=value=>child.stdin.write(JSON.stringify(value)+'\n');
const deadline=setTimeout(()=>{child.kill('SIGTERM');console.error(errors);console.error(events.slice(-12));process.exitCode=1;},20000);
child.stderr.on('data',b=>errors+=b);
child.stdout.on('data',b=>{
  buffer+=b; const lines=buffer.split('\n');buffer=lines.pop();
  for(const line of lines) {
    if(!line)continue; const e=JSON.parse(line);events.push(e);
    if(e.type==='response'&&e.id==='state'&&!ready){ready=true;send({id:'prompt',type:'prompt',message:'Run the deterministic integration check.'});}
    if(e.type==='extension_ui_request'&&e.method==='select')send({type:'extension_ui_response',id:e.id,value:e.options[0]});
    if(e.type==='agent_settled')send({id:'history',type:'get_messages'});
    if(e.type==='response'&&e.id==='history') {
      try {
        const snapshots=events.filter(x=>x.type==='tool_execution_end'&&x.toolName==='todo').map(x=>x.result.details.gentleTodo);
        assert.equal(snapshots.length,2);assert.equal(snapshots[0].tasks.length,3);
        assert.ok(snapshots[1].tasks.every(t=>t.status==='done'));
        const question=events.find(x=>x.type==='tool_execution_end'&&x.toolName==='ask_user_question');
        assert.equal(question.result.details.answers[0].answer,'Yes');
        assert.ok(e.data.messages.some(m=>m.role==='toolResult'&&m.details?.gentleTodo));
        assert.ok(events.some(x=>x.type==='message_update'));
        writeFileSync(join(temp,'events.json'),JSON.stringify(events,null,2));
        console.log(JSON.stringify({passed:true,pi:'1.4.0',gentle:'4.3.0',snapshots:snapshots.length,questionAnswer:'Yes',session,events:join(temp,'events.json')}));
      } catch(error){console.error(error);console.error(errors);process.exitCode=1;}
      clearTimeout(deadline);child.stdin.end();setTimeout(()=>child.kill('SIGTERM'),200).unref();
    }
  }
});
child.on('exit',code=>{clearTimeout(deadline);if(!events.some(e=>e.id==='history')){console.error(errors);console.error('Pi exited before integration completed',code);process.exitCode=1;}});
send({id:'state',type:'get_state'});
