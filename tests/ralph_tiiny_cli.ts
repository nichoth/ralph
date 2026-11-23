import { test } from '@substrate-system/tapzero'
import type { Test } from '@substrate-system/tapzero'
import { spawnSync } from 'node:child_process'
import {
    accessSync, constants, existsSync, mkdirSync, mkdtempSync,
    readFileSync, rmSync, symlinkSync, writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join, resolve } from 'node:path'

// Offline integration tests: only the runner uses Bash. Node manages all
// fixtures, assertions, and stubs; real Pi and Tiiny commands are unreachable.
const runner = process.env.RALPH_TEST_RUNNER ||
    resolve(import.meta.dirname, '../ralph_tiiny.sh')
const commands = [
    'bash', 'touch', 'mktemp', 'cat', 'tee', 'tail', 'jq', 'git',
] as const

// Every command is either a resolved path or throws before tests run.
const executables = Object.fromEntries(commands.map((command) => {
    return [command, findCommand(command)]
})) as Record<typeof commands[number], string>

const automatic = 'automatic (sole loaded model)'

// Captured from Tiiny CLI v0.0.7: --json still renders this table.
const loadedTable = [
    '+------------------------+----------------------------------+' +
        '------------------+---------+------+-------------------+' +
        '-------------------+-------+',
    '|Name                    |Model ID                          |' +
        'Type              |NPU Usage|Source|Started            |' +
        'Last Used          |Aliases|',
    '+------------------------+----------------------------------+' +
        '------------------+---------+------+-------------------+' +
        '-------------------+-------+',
    '|Ornith-1.5-35B-A3B-Turbo|ornith-ai/Ornith-1.5-35B-A3B-Turbo|' +
        'Image-Text-to-Text|49%      |Store |2026-11-23 11:08:11|' +
        '2026-11-23 11:08:26|default|',
    '+------------------------+----------------------------------+' +
        '------------------+---------+------+-------------------+' +
        '-------------------+-------+',
].join('\n') + '\n'

for (const args of [[], ['-m', 'ornith-ai/Ornith-1.5-35B-A3B-Turbo']]) {
    cliTest(`selects a loaded model from Tiiny's table: ${args}`,
        (t, f) => {
            f.stub('tiiny', `
                process.stdout.write(${JSON.stringify(loadedTable)});
            `)
            const result = f.run(args)
            result.status(0)
            result.text('Selected Tiiny model: Ornith-1.5-35B-A3B-Turbo ' +
                '(ornith-ai/Ornith-1.5-35B-A3B-Turbo)')
        })
}

cliTest('multiple loaded table rows require a selection', (t, f) => {
    const table = loadedTable.replace(/\n\+[^\n]+\n$/, '\n' +
        '|Second Model|custom/second|Text Generation|10%|Store|' +
        '2026-11-23 11:08:11|2026-11-23 11:08:26||\n' +
        loadedTable.split('\n')[0] + '\n')
    f.stub('tiiny', `process.stdout.write(${JSON.stringify(table)});`)
    const result = f.run()
    result.status(1)
    result.text('ornith-ai/Ornith-1.5-35B-A3B-Turbo')
    result.text('custom/second')
    result.text('multiple loaded models')
})

cliTest('an empty loaded table reports no loaded models', (t, f) => {
    const table = loadedTable.split('\n').filter((line) =>
        !line.startsWith('|Ornith-')).join('\n')
    f.stub('tiiny', `process.stdout.write(${JSON.stringify(table)});`)
    const result = f.run()
    result.status(1)
    result.text('no loaded Tiiny models')
})

for (const table of [
    loadedTable.replace('Model ID', 'Unknown '),
    loadedTable.replace('|Ornith-', '|broken|Ornith-'),
    loadedTable.replace('ornith-ai/Ornith-1.5-35B-A3B-Turbo', ' '),
    loadedTable + 'unexpected output\n',
]) {
    cliTest('rejects malformed model tables', (t, f) => {
        f.stub('tiiny', `process.stdout.write(${JSON.stringify(table)});`)
        const result = f.run()
        result.status(1)
        result.text('malformed model data')
    })
}

cliTest('help works without local prerequisites', (t, f) => {
    for (const command of ['pi', 'tiiny', 'jq', 'git']) {
        f.remove(join(f.bin, command))
    }
    f.remove(join(f.repo, 'PROMPT.md'))
    f.remove(join(f.repo, 'specs/prd.json'))
    const result = f.run(['--help'])
    result.status(0)
    for (const text of [
        'Usage:', '--model', '-m', 'MAX_ITERATIONS', 'MAX_TURNS_PER_SESSION',
        'default: 10', 'default: 80', 'loaded', 'sole loaded model',
    ]) result.text(text)
    t.ok(!existsSync(join(f.repo, 'progress.log')), 'help creates no log')
})

cliTest('defaults create an empty progress log', (t, f) => {
    f.run().config(10, 80, automatic)
    t.equal(readFileSync(join(f.repo, 'progress.log'), 'utf8'), '',
        'new progress log is empty')
})

cliTest('one positional limit keeps the default turn cap', (t, f) => {
    f.run(['7']).config(7, 80, automatic)
})

for (const [mode, message] of [
    ['zero', 'no loaded Tiiny models'],
    ['malformed', 'malformed model data'],
    ['fail', 'cannot discover loaded Tiiny models'],
]) {
    cliTest(`model discovery: ${mode}`, (t, f) => {
        const result = f.run([], { TIINY_STUB_MODE:mode })
        result.status(1)
        result.text(message)
    })
}

cliTest('multiple loaded models require a selection', (t, f) => {
    const result = f.run([], { TIINY_STUB_MODE:'many' })
    result.status(1)
    for (const text of ['Loaded model IDs:', 'one', 'two',
        'multiple loaded models']) result.text(text)
})

for (const model of ['one', 'absent']) {
    cliTest(`select loaded model: ${model}`, (t, f) => {
        const result = f.run(['-m', model], { TIINY_STUB_MODE:'many' })
        result.status(model === 'one' ? 0 : 1)
        result.text(model === 'one' ? 'Selected Tiiny model: One (one)'
            : "model 'absent' is not currently loaded")
    })
}

for (const flag of ['--model', '-m']) {
    const model = 'ornith-ai/Ornith-1.5-35B-A3B-Turbo'
    for (const [position, args] of [
        ['before', [flag, model, '3', '9']],
        ['between', ['3', flag, model, '9']],
        ['after', ['3', '9', flag, model]],
    ] as const) {
        cliTest(`${flag} ${position} positional limits`, (t, f) => {
            f.run(args).config(3, 9, model)
        })
    }
}

cliTest('model IDs can contain spaces', (t, f) => {
    const model = 'custom/model with spaces'
    f.run(['-m', model]).config(10, 80, model)
})

cliTest('leading zeroes are parsed as decimal', (t, f) => {
    f.run(['0008', '0009']).config(8, 9, automatic)
})

for (const flag of ['--model', '-m']) {
    for (const [name, args] of [
        ['missing', [flag]], ['empty', [flag, '']],
        ['option', [flag, '--help']],
    ] as const) {
        cliTest(`${flag} rejects ${name} model ID`, (t, f) => {
            const result = f.run(args)
            result.status(2)
            result.text(`${flag} requires a model ID`)
            result.text('Usage:')
            t.ok(!existsSync(join(f.repo, 'progress.log')),
                'invalid CLI creates no log')
        })
    }
}

for (const flag of ['--unknown', '-x', '--model=example']) {
    cliTest(`unknown option: ${flag}`, (t, f) => {
        const result = f.run([flag])
        result.status(2)
        result.text('unknown option')
        result.text('Usage:')
    })
}

cliTest('too many positional arguments', (t, f) => {
    const result = f.run(['1', '2', '3'])
    result.status(2)
    result.text('too many positional arguments')
})

for (const value of [
    '0', '000', '-1', '1.5', 'abc', '1e3', '+2', '', ' 2', '2 ', '1+2',
]) {
    for (const position of ['first', 'second']) {
        cliTest(`invalid ${position} limit: ${JSON.stringify(value)}`,
            (t, f) => {
                const args = position === 'first' ? [value] : ['1', value]
                const result = f.run(args)
                result.status(2)
                result.text('positive integer')
                result.text('Usage:')
            })
    }
}

for (const command of ['pi', 'tiiny', 'jq', 'git']) {
    cliTest(`missing command: ${command}`, (t, f) => {
        f.remove(join(f.bin, command))
        const result = f.run()
        result.status(1)
        result.text(`required command '${command}' not found in PATH`)
        t.ok(!existsSync(join(f.repo, 'progress.log')),
            'missing command creates no log')
    })
}

for (const file of ['PROMPT.md', 'specs/prd.json']) {
    cliTest(`missing file: ${file}`, (t, f) => {
        f.remove(join(f.repo, file))
        const result = f.run()
        result.status(1)
        result.text(`missing required file: ${file}`)
        t.ok(!existsSync(join(f.repo, 'progress.log')),
            'missing file creates no log')
    })
}

cliTest('requires a Git repository', (t, f) => {
    f.remove(join(f.repo, '.git'))
    const result = f.run()
    result.status(1)
    result.text('working Git repository')
})

cliTest('rejects a bare Git repository', (t, f) => {
    f.git('init', '-q', '--bare', 'bare')
    f.repo = join(f.repo, 'bare')
    const result = f.run()
    result.status(1)
    result.text('working Git repository')
})

for (const output of ['', 'true\n']) {
    cliTest(`rejects failed Git check: ${JSON.stringify(output)}`,
        (t, f) => {
            f.stub('git', `
                process.stdout.write(${JSON.stringify(output)});
                process.exit(1);
            `)
            const result = f.run()
            result.status(1)
            result.text('working Git repository')
        })
}

cliTest('required files are resolved from cwd', (t, f) => {
    f.repo = join(f.repo, 'nested')
    mkdirSync(f.repo)
    const result = f.run()
    result.status(1)
    result.text('missing required file: PROMPT.md')
})

cliTest('preserves existing progress', (t, f) => {
    f.write('progress.log', 'existing progress\n')
    f.run().status(0)
    t.equal(readFileSync(join(f.repo, 'progress.log'), 'utf8'),
        'existing progress\n', 'existing progress is unchanged')
})

cliTest('progress log must be a regular file', (t, f) => {
    mkdirSync(join(f.repo, 'progress.log'))
    const result = f.run()
    result.status(1)
    result.text('progress.log must be a regular file')
})

cliTest('reports failure to create progress log', (t, f) => {
    f.stub('touch', 'process.exit(1);')
    const result = f.run()
    result.status(1)
    result.text('cannot create or update progress.log')
})

cliTest('task loop selects priority and supplies recent context', (t, f) => {
    f.stories([
        { id:'high', title:'High', priority:1 },
        { id:'low', title:'Low', priority:9, passes:false },
        { id:'done', title:'Done', priority:0, passes:true },
    ])
    f.write('progress.log', Array.from({ length:9 },
        (_, index) => `line-${index + 1}\n`).join(''))
    loopStub(f)
    const result = f.run(['1', '4'])
    result.status(0)
    result.text('Reached MAX_ITERATIONS=1')
    const calls = f.calls()
    t.ok(calls.includes('Work on EXACTLY ONE task: [high] High'),
        'selects the highest priority pending story')
    t.ok(calls.includes('line-2'), 'includes the last eight log lines')
    t.ok(!calls.includes('line-1'), 'omits older log lines')
    t.ok(calls.includes('Remaining tasks'), 'includes remaining tasks')
})

cliTest('malformed PRD exits with status 3', (t, f) => {
    f.write('specs/prd.json', '{"userStories": {}}\n')
    const result = f.run()
    result.status(3)
    result.text('missing/malformed')
})

cliTest('renders Pi JSON events', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    const events = [
        { type:'agent_start' },
        {
            type:'auto_retry_start',
            attempt:1,
            maxAttempts:2,
            errorMessage:'temporary'
        },
        {
            type:'message_end',
            message:{
                role:'assistant',
                stopReason:'toolUse',
                content:[
                    { type:'text', text:'hello' },
                ]
            }
        },
        {
            type:'tool_execution_start',
            toolName:'bash',
            toolCallId:'call-1',
            args:{ command:'git status' }
        },
        {
            type:'tool_execution_end',
            toolName:'bash',
            toolCallId:'call-1',
            isError:false,
            result:{ content:[{ type:'text', text:'working tree clean' }] }
        },
        { type:'message_end', message:assistantMessage() },
        { type:'agent_end', messages:[assistantMessage()] },
    ]
    f.stub('pi', `
        for (const event of ${JSON.stringify(events)}) {
            console.log(JSON.stringify(event));
        }
    `)
    const result = f.run(['1'])
    result.status(0)
    for (const text of ['session start', 'retry 1/2', 'hello',
        'tool bash:', 'working tree clean', 'session end']) result.text(text)
    result.absent('Pi failures')
    result.absent('Retained Pi capture:')
})

cliTest('reports missing assistant terminal output', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    f.stub('pi', `console.log(JSON.stringify({
        type: 'agent_end', messages: [],
    }));`)
    const result = f.run(['1'])
    result.status(0)
    result.text('missing assistant terminal output')
})

for (const stopReason of ['error', 'aborted', 'length', 'toolUse']) {
    cliTest(`reports Pi terminal outcome: ${stopReason}`, (t, f) => {
        f.stories([{ id:'todo', title:'Todo' }])
        loopStub(f, { text:'failed', stopReason })
        const result = f.run(['1'])
        result.status(0)
        result.text(`Pi terminal outcome: ${stopReason}`)
        result.text('Pi session failed validation (process status 0)')
        result.absent('Pi session exited with status 1')
        const captures = result.captures()
        t.equal(captures.length, 1, 'one failed capture retained')
        for (const capture of captures) {
            t.ok(readFileSync(capture, 'utf8').includes(stopReason),
                'retained capture contains the raw failure')
        }
    })
}

cliTest('renders model errors even when Pi exits zero', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    const message = assistantMessage({
        content:[], stopReason:'error', errorMessage:'inference unavailable',
    })
    piEvents(f, [
        { type:'message_end', message },
        { type:'agent_end', messages:[message] },
    ])
    const result = f.run(['3'])
    result.status(4)
    result.text('inference unavailable')
    result.text('Failed 3 consecutive Pi sessions')
    t.equal(result.captures().length, 3, 'all failed captures survive exit')
})

cliTest('errorMessage prevents a successful classification', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    const message = assistantMessage({ errorMessage:'provider failure' })
    piEvents(f, [{ type:'agent_end', messages:[message] }])
    const result = f.run(['1'])
    result.text('Pi terminal outcome: error')
    result.text('provider failure')
    t.equal(result.captures().length, 1, 'failed capture retained')
})

for (const events of [
    [],
    [{ type:'message_end', message:assistantMessage() }],
    [{ type:'agent_end', messages:[assistantMessage()] }, 'bad JSON'],
]) {
    cliTest('rejects incomplete or malformed Pi output', (t, f) => {
        f.stories([{ id:'todo', title:'Todo' }])
        piEvents(f, events)
        const result = f.run(['1'])
        result.text('Pi session failed validation (process status 0)')
        t.equal(result.captures().length, 1, 'invalid capture retained')
    })
}

cliTest('uses the final assistant after a recovered error', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    const failed = assistantMessage({
        stopReason:'error', errorMessage:'temporary error',
    })
    const success = assistantMessage()
    piEvents(f, [
        { type:'message_end', message:failed },
        { type:'agent_end', messages:[failed] },
        { type:'message_end', message:success },
        { type:'agent_end', messages:[failed, success] },
    ])
    const result = f.run(['1'])
    result.absent('Pi failures')
    t.equal(result.captures().length, 0, 'successful capture removed')
})

cliTest('trusts COMPLETE only in the final successful assistant', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f, { text:'<promise>COMPLETE</promise>' })
    const result = f.run(['1'], { PI_MODE:'complete_two' })
    result.status(0)
    result.text('MISSION ACCOMPLISHED')
    result.absent('Retained Pi capture:')
})

cliTest('ignores COMPLETE in earlier assistant and tool text', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    const marker = '<promise>COMPLETE</promise>'
    piEvents(f, [
        {
            type:'message_end',
            message:assistantMessage({
                content:[{ type:'text', text:marker }], stopReason:'toolUse',
            })
        },
        {
            type:'agent_end',
            messages:[
                { role:'toolResult', content:[{ type:'text', text:marker }] },
                assistantMessage(),
            ]
        },
    ])
    const result = f.run(['1'])
    result.absent('ignoring COMPLETE')
    result.absent('Pi failures')
})

cliTest('ignores COMPLETE while tasks remain', (t, f) => {
    f.stories([{ id:'todo', title:'Todo', passes:false }])
    loopStub(f, { text:'<promise>COMPLETE</promise>' })
    const result = f.run(['1'])
    result.status(0)
    result.text('ignoring COMPLETE')
})

cliTest('Pi uses the Tiiny device address as its endpoint', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    f.run(['1'], { PI_MODE:'commit' }).status(0)
    t.ok(f.calls().includes('endpoint=http://192.0.2.7/v1\n'),
        'endpoint comes from the configured device address')
})

cliTest('TIINY_BASE_URL overrides the device address', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    const endpoint = 'http://198.51.100.3:9000/v1'
    f.run(['1'], { PI_MODE:'commit', TIINY_BASE_URL:endpoint }).status(0)
    t.ok(f.calls().includes(`endpoint=${endpoint}\n`),
        'endpoint comes from TIINY_BASE_URL')
})

cliTest('an IPv6 device address is bracketed', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    writeFileSync(join(f.env.HOME!, '.local/tiiny/config.json'),
        JSON.stringify({ deviceAddress:'fe80::1%en0' }))
    f.run(['1'], { PI_MODE:'commit' }).status(0)
    t.ok(f.calls().includes('endpoint=http://[fe80::1%25en0]/v1\n'),
        'endpoint brackets and escapes the IPv6 address')
})

for (const config of ['missing', 'no address']) {
    cliTest(`no Tiiny device address: ${config}`, (t, f) => {
        const path = join(f.env.HOME!, '.local/tiiny/config.json')
        if (config === 'missing') f.remove(path)
        else writeFileSync(path, JSON.stringify({ discovery:{} }))
        loopStub(f)
        f.run(['1']).status(1)
        t.ok(!existsSync(join(f.env.HOME!, 'calls')), 'Pi never runs')
    })
}

cliTest('a new commit counts as progress', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    const result = f.run(['1'], { PI_MODE:'commit' })
    result.status(0)
    result.text('Progress (commits:')
})

cliTest('dirty files stall and stale Wrangler state is cleaned', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    const result = f.run(['4'])
    result.status(2)
    result.text('No progress this session (stall 4/4)')
    const state = join(f.repo, '.wrangler/state/v3')
    mkdirSync(state, { recursive:true })
    f.run(['3']).status(0)
    t.ok(!existsSync(state), 'Wrangler state was cleaned')
})

cliTest('three failed sessions stop with status 4', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    const result = f.run(['3'], { PI_MODE:'fail' })
    result.status(4)
    result.text('Failed 3 consecutive Pi sessions')
    result.text('Pi process exited with status 9')
    t.equal(result.captures().length, 3, 'nonzero exits retain captures')
})

cliTest('a later successful run reaches its iteration limit', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    f.run(['1'], { PI_MODE:'fail' }).status(0)
    const result = f.run(['1'])
    result.status(0)
    result.text('Reached MAX_ITERATIONS=1')
})

cliTest('interruption retains the current capture', (t, f) => {
    f.stories([{ id:'todo', title:'Todo' }])
    loopStub(f)
    f.stub('tee', `
        const fs = require('node:fs');
        const output = fs.readFileSync(0, 'utf8');
        fs.writeFileSync(process.argv[2], output);
        process.stdout.write(output);
        process.kill(process.ppid, 'SIGINT');
    `)
    const result = f.run(['1'])
    result.status(130)
    const captures = result.captures()
    t.equal(captures.length, 1, 'interrupted capture retained')
    for (const capture of captures) {
        t.ok(readFileSync(capture, 'utf8').includes('message_end'),
            'retained capture contains session output')
    }
})

cliTest('reports sessions completing multiple stories', (t, f) => {
    f.stories([{ id:'one', title:'One' }, { id:'two', title:'Two' }])
    loopStub(f)
    const result = f.run(['1'], { PI_MODE:'complete_two' })
    result.status(0)
    result.text('completed more than one task')
})

type Story = {
    id:string;
    title:string;
    priority?:number;
    passes?:boolean;
}

type CliResult = {
    status(code:number):void;
    text(value:string):void;
    absent(value:string):void;
    captures():Array<string>;
    config(iterations:number, turns:number, model:string):void;
}

type Fixture = {
    repo:string;
    bin:string;
    env:NodeJS.ProcessEnv;
    write(path:string, content:string):void;
    stories(userStories:ReadonlyArray<Story>):void;
    remove(path:string):void;
    stub(command:string, source:string):void;
    git(...args:Array<string>):void;
    run(args?:ReadonlyArray<string>, overrides?:NodeJS.ProcessEnv):CliResult;
    calls():string;
}

function cliTest (
    name:string,
    body:(t:Test, fixture:Fixture) => void
):void {
    test(name, (t) => {
        const root = mkdtempSync(join(tmpdir(), 'ralph-tiiny-cli.'))
        const repo = join(root, 'work repo')
        const bin = join(root, 'bin')
        const calls = join(root, 'calls')
        const unexpected = join(root, 'unexpected')
        const env:NodeJS.ProcessEnv = {
            ...process.env,
            PATH:bin,
            HOME:root,
            TMPDIR:root,
            CALLS:calls,
            UNEXPECTED_CALLS:unexpected,
            GIT_CONFIG_NOSYSTEM:'1',
            GIT_CONFIG_GLOBAL:'/dev/null',
            GIT_AUTHOR_NAME:'CLI Test',
            GIT_AUTHOR_EMAIL:'cli-test@example.invalid',
            GIT_COMMITTER_NAME:'CLI Test',
            GIT_COMMITTER_EMAIL:'cli-test@example.invalid',
        }
        for (const key of [
            'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
        ]) {
            delete env[key]
        }
        const fixture:Fixture = {
            repo,
            bin,
            env,
            write (path, content) {
                writeFileSync(join(this.repo, path), content)
            },
            stories (userStories) {
                this.write('specs/prd.json', JSON.stringify({ userStories }))
            },
            remove (path) {
                rmSync(path, { recursive:true, force:true })
            },
            stub (command, source) {
                this.remove(join(bin, command))
                writeFileSync(join(bin, command),
                    `#!${process.execPath}\n${source}\n`, { mode:0o755 })
            },
            git (...args) {
                const result = spawnSync(executables.git, args, {
                    cwd:this.repo, env, encoding:'utf8',
                })
                if (result.error) throw result.error
                if (result.status !== 0) {
                    throw new Error(`git failed: ${result.stderr}`)
                }
            },
            run (args = [], overrides = {}) {
                const modelIndex = args.findIndex((arg) =>
                    arg === '--model' || arg === '-m')
                const result = spawnSync(executables.bash,
                    [runner, ...args], {
                        cwd:this.repo,
                        env:{
                            ...env,
                            TIINY_STUB_MODEL:modelIndex < 0
                                ? 'test/model' : args[modelIndex + 1] || '',
                            TIINY_STUB_MODE:'one',
                            PI_MODE:'noop',
                            ...overrides,
                        },
                        encoding:'utf8',
                        timeout:15000,
                    })
                if (result.error) throw result.error
                const output = result.stdout + result.stderr
                return {
                    status (code) {
                        t.equal(result.status, code,
                            `exit ${code} (got ${result.status})`)
                        if (result.status !== code) t.comment(output)
                    },
                    text (value) {
                        t.ok(output.includes(value), `output: ${value}`)
                        if (!output.includes(value)) t.comment(output)
                    },
                    absent (value) {
                        t.ok(!output.includes(value), `no output: ${value}`)
                        if (output.includes(value)) t.comment(output)
                    },
                    captures () {
                        const paths = Array.from(output.matchAll(
                            /Retained Pi capture: (.+)/g
                        ), (match) => match[1])
                        for (const path of paths) {
                            t.ok(existsSync(path), 'capture exists after exit')
                        }
                        return paths
                    },
                    config (iterations, turns, model) {
                        this.status(0)
                        this.text(`MAX_ITERATIONS=${iterations}`)
                        this.text(`MAX_TURNS_PER_SESSION=${turns}`)
                        this.text(`Requested model: ${model}`)
                    },
                }
            },
            calls () {
                return readFileSync(calls, 'utf8')
            },
        }
        try {
            mkdirSync(join(repo, 'specs'), { recursive:true })
            mkdirSync(bin)
            mkdirSync(join(root, '.local/tiiny'), { recursive:true })
            writeFileSync(join(root, '.local/tiiny/config.json'),
                JSON.stringify({ deviceAddress:'192.0.2.7' }))
            for (const command of commands) {
                symlinkSync(executables[command], join(bin, command))
            }
            fixture.git('init', '-q')
            fixture.write('PROMPT.md', 'test prompt\n')
            fixture.stories([])
            fixture.stub('pi', `
                require('node:fs').appendFileSync(
                    process.env.UNEXPECTED_CALLS, 'pi\\n');
                process.exit(97);
            `)
            fixture.stub('tiiny', `
                if (JSON.stringify(process.argv.slice(2)) !==
                    JSON.stringify(['ls', '--loaded', '--json'])) {
                    require('node:fs').appendFileSync(
                        process.env.UNEXPECTED_CALLS, 'tiiny\\n');
                    process.exit(97);
                }
                const mode = process.env.TIINY_STUB_MODE;
                if (mode === 'fail') process.exit(42);
                const models = mode === 'malformed' ? {}
                    : mode === 'zero' ? []
                    : mode === 'many' ? [
                        { id: 'one', name: 'One', state: 'running' },
                        { id: 'two', name: 'Two', state: 'loaded' },
                    ] : [{
                        id: process.env.TIINY_STUB_MODEL,
                        name: 'Test Model', state: 'running',
                    }];
                console.log(JSON.stringify({ models }));
            `)
            body(t, fixture)
            t.ok(!existsSync(unexpected), 'no unexpected external commands')
        } finally {
            rmSync(root, { recursive:true, force:true })
        }
    })
}

function loopStub (
    fixture:Fixture,
    { text = 'done', stopReason = 'stop' }:{
        text?:string;
        stopReason?:string;
    } = {}
):void {
    fixture.stub('pi', `
        const fs = require('node:fs');
        const { execFileSync } = require('node:child_process');
        fs.appendFileSync(process.env.CALLS,
            'endpoint=' + process.env.RALPH_TIINY_ENDPOINT + '\\n' +
            process.argv.slice(2).join(' ') + '\\n' +
            fs.readFileSync(0, 'utf8'));
        const mode = process.env.PI_MODE;
        if (mode === 'fail') {
            console.log(JSON.stringify({ type: 'agent_start' }));
            process.exit(9);
        }
        if (mode === 'commit') {
            fs.appendFileSync('progress.log', 'stub\\n');
            execFileSync('git', ['add', 'progress.log']);
            execFileSync('git', ['commit', '-qm', 'stub progress']);
        }
        if (mode === 'complete_two') {
            const prd = JSON.parse(fs.readFileSync('specs/prd.json', 'utf8'));
            prd.userStories[0].passes = true;
            if (prd.userStories[1]) prd.userStories[1].passes = true;
            fs.writeFileSync('specs/prd.json', JSON.stringify(prd));
        }
        const message = ${JSON.stringify(assistantMessage({
            content:[{ type:'text', text }], stopReason,
        }))};
        console.log(JSON.stringify({ type: 'message_end', message }));
        console.log(JSON.stringify({
            type: 'agent_end', messages: [message],
        }));
    `)
}

function assistantMessage (overrides:Record<string, unknown> = {}) {
    return {
        role:'assistant',
        content:[{ type:'text', text:'done' }],
        api:'openai-completions',
        provider:'tiiny',
        model:'test/model',
        usage:{
            input:1,
            output:1,
            cacheRead:0,
            cacheWrite:0,
            totalTokens:2,
            cost:{ input:0, output:0, cacheRead:0, cacheWrite:0, total:0 },
        },
        stopReason:'stop',
        timestamp:1,
        ...overrides,
    }
}

function piEvents (fixture:Fixture, events:ReadonlyArray<unknown>):void {
    fixture.stub('pi', `
        for (const event of ${JSON.stringify(events)}) {
            console.log(typeof event === 'string'
                ? event : JSON.stringify(event));
        }
    `)
}

function findCommand (command:string):string {
    for (const directory of (process.env.PATH || '').split(delimiter)) {
        const path = resolve(directory, command)
        try {
            accessSync(path, constants.X_OK)
            return path
        } catch (error) {
            const missing = error instanceof Error && 'code' in error &&
                ['ENOENT', 'EACCES', 'ENOTDIR'].includes(String(error.code))
            if (!missing) throw error
        }
    }
    throw new Error(`required test command not found: ${command}`)
}
