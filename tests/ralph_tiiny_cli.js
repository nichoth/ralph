const { test } = require('tapzero');
const { spawnSync } = require('node:child_process');
const {
    accessSync, constants, existsSync, mkdirSync, mkdtempSync,
    readFileSync, rmSync, symlinkSync, writeFileSync,
} = require('node:fs');
const { tmpdir } = require('node:os');
const { delimiter, join, resolve } = require('node:path');

// Offline integration tests: only the runner uses Bash. Node manages all
// fixtures, assertions, and stubs; real Pi and Tiiny commands are unreachable.
const runner = resolve(__dirname, '../ralph_tiiny.sh');
const commands = [
    'bash', 'touch', 'mktemp', 'cat', 'tee', 'tail', 'jq', 'git',
];
const executables = Object.fromEntries(commands.map((command) => {
    for (const directory of process.env.PATH.split(delimiter)) {
        const path = resolve(directory, command);
        try {
            accessSync(path, constants.X_OK);
            return [command, path];
        } catch (error) {
            if (!['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) {
                throw error;
            }
        }
    }
    throw new Error(`required test command not found: ${command}`);
}));

const automatic = 'automatic (sole loaded model)';

cliTest('help works without local prerequisites', (t, f) => {
    for (const command of ['pi', 'tiiny', 'jq', 'git']) {
        f.remove(join(f.bin, command));
    }
    f.remove(join(f.repo, 'PROMPT.md'));
    f.remove(join(f.repo, 'specs/prd.json'));
    const result = f.run(['--help']);
    result.status(0);
    for (const text of [
        'Usage:', '--model', '-m', 'MAX_ITERATIONS', 'MAX_TURNS_PER_SESSION',
        'default: 10', 'default: 80', 'loaded', 'sole loaded model',
    ]) result.text(text);
    t.ok(!existsSync(join(f.repo, 'progress.log')), 'help creates no log');
});

cliTest('defaults create an empty progress log', (t, f) => {
    f.run().config(10, 80, automatic);
    t.equal(readFileSync(join(f.repo, 'progress.log'), 'utf8'), '',
        'new progress log is empty');
});

cliTest('one positional limit keeps the default turn cap', (t, f) => {
    f.run(['7']).config(7, 80, automatic);
});

for (const [mode, message] of [
    ['zero', 'no loaded Tiiny models'],
    ['malformed', 'malformed model data'],
    ['fail', 'cannot discover loaded Tiiny models'],
]) {
    cliTest(`model discovery: ${mode}`, (t, f) => {
        const result = f.run([], { TIINY_STUB_MODE: mode });
        result.status(1);
        result.text(message);
    });
}

cliTest('multiple loaded models require a selection', (t, f) => {
    const result = f.run([], { TIINY_STUB_MODE: 'many' });
    result.status(1);
    for (const text of ['Loaded model IDs:', 'one', 'two',
        'multiple loaded models']) result.text(text);
});

for (const model of ['one', 'absent']) {
    cliTest(`select loaded model: ${model}`, (t, f) => {
        const result = f.run(['-m', model], { TIINY_STUB_MODE: 'many' });
        result.status(model === 'one' ? 0 : 1);
        result.text(model === 'one' ? 'Selected Tiiny model: One (one)'
            : "model 'absent' is not currently loaded");
    });
}

for (const flag of ['--model', '-m']) {
    const model = 'ornith-ai/Ornith-1.5-35B-A3B-Turbo';
    for (const [position, args] of [
        ['before', [flag, model, '3', '9']],
        ['between', ['3', flag, model, '9']],
        ['after', ['3', '9', flag, model]],
    ]) {
        cliTest(`${flag} ${position} positional limits`, (t, f) => {
            f.run(args).config(3, 9, model);
        });
    }
}

cliTest('model IDs can contain spaces', (t, f) => {
    const model = 'custom/model with spaces';
    f.run(['-m', model]).config(10, 80, model);
});

cliTest('leading zeroes are parsed as decimal', (t, f) => {
    f.run(['0008', '0009']).config(8, 9, automatic);
});

for (const flag of ['--model', '-m']) {
    for (const [name, args] of [
        ['missing', [flag]], ['empty', [flag, '']],
        ['option', [flag, '--help']],
    ]) {
        cliTest(`${flag} rejects ${name} model ID`, (t, f) => {
            const result = f.run(args);
            result.status(2);
            result.text(`${flag} requires a model ID`);
            result.text('Usage:');
            t.ok(!existsSync(join(f.repo, 'progress.log')),
                'invalid CLI creates no log');
        });
    }
}

for (const flag of ['--unknown', '-x', '--model=example']) {
    cliTest(`unknown option: ${flag}`, (t, f) => {
        const result = f.run([flag]);
        result.status(2);
        result.text('unknown option');
        result.text('Usage:');
    });
}

cliTest('too many positional arguments', (t, f) => {
    const result = f.run(['1', '2', '3']);
    result.status(2);
    result.text('too many positional arguments');
});

for (const value of [
    '0', '000', '-1', '1.5', 'abc', '1e3', '+2', '', ' 2', '2 ', '1+2',
]) {
    for (const position of ['first', 'second']) {
        cliTest(`invalid ${position} limit: ${JSON.stringify(value)}`,
            (t, f) => {
                const args = position === 'first' ? [value] : ['1', value];
                const result = f.run(args);
                result.status(2);
                result.text('positive integer');
                result.text('Usage:');
            });
    }
}

for (const command of ['pi', 'tiiny', 'jq', 'git']) {
    cliTest(`missing command: ${command}`, (t, f) => {
        f.remove(join(f.bin, command));
        const result = f.run();
        result.status(1);
        result.text(`required command '${command}' not found in PATH`);
        t.ok(!existsSync(join(f.repo, 'progress.log')),
            'missing command creates no log');
    });
}

for (const file of ['PROMPT.md', 'specs/prd.json']) {
    cliTest(`missing file: ${file}`, (t, f) => {
        f.remove(join(f.repo, file));
        const result = f.run();
        result.status(1);
        result.text(`missing required file: ${file}`);
        t.ok(!existsSync(join(f.repo, 'progress.log')),
            'missing file creates no log');
    });
}

cliTest('requires a Git repository', (t, f) => {
    f.remove(join(f.repo, '.git'));
    const result = f.run();
    result.status(1);
    result.text('working Git repository');
});

cliTest('rejects a bare Git repository', (t, f) => {
    f.git('init', '-q', '--bare', 'bare');
    f.repo = join(f.repo, 'bare');
    const result = f.run();
    result.status(1);
    result.text('working Git repository');
});

for (const output of ['', 'true\n']) {
    cliTest(`rejects failed Git check: ${JSON.stringify(output)}`,
        (t, f) => {
            f.stub('git', `
                process.stdout.write(${JSON.stringify(output)});
                process.exit(1);
            `);
            const result = f.run();
            result.status(1);
            result.text('working Git repository');
        });
}

cliTest('required files are resolved from cwd', (t, f) => {
    f.repo = join(f.repo, 'nested');
    mkdirSync(f.repo);
    const result = f.run();
    result.status(1);
    result.text('missing required file: PROMPT.md');
});

cliTest('preserves existing progress', (t, f) => {
    f.write('progress.log', 'existing progress\n');
    f.run().status(0);
    t.equal(readFileSync(join(f.repo, 'progress.log'), 'utf8'),
        'existing progress\n', 'existing progress is unchanged');
});

cliTest('progress log must be a regular file', (t, f) => {
    mkdirSync(join(f.repo, 'progress.log'));
    const result = f.run();
    result.status(1);
    result.text('progress.log must be a regular file');
});

cliTest('reports failure to create progress log', (t, f) => {
    f.stub('touch', 'process.exit(1);');
    const result = f.run();
    result.status(1);
    result.text('cannot create or update progress.log');
});

cliTest('task loop selects priority and supplies recent context', (t, f) => {
    f.stories([
        { id: 'high', title: 'High', priority: 1 },
        { id: 'low', title: 'Low', priority: 9, passes: false },
        { id: 'done', title: 'Done', priority: 0, passes: true },
    ]);
    f.write('progress.log', Array.from({ length: 9 },
        (_, index) => `line-${index + 1}\n`).join(''));
    loopStub(f);
    const result = f.run(['1', '4']);
    result.status(0);
    result.text('Reached MAX_ITERATIONS=1');
    const calls = f.calls();
    t.ok(calls.includes('Work on EXACTLY ONE task: [high] High'),
        'selects the highest priority pending story');
    t.ok(calls.includes('line-2'), 'includes the last eight log lines');
    t.ok(!calls.includes('line-1'), 'omits older log lines');
    t.ok(calls.includes('Remaining tasks'), 'includes remaining tasks');
});

cliTest('malformed PRD exits with status 3', (t, f) => {
    f.write('specs/prd.json', '{"userStories": {}}\n');
    const result = f.run();
    result.status(3);
    result.text('missing/malformed');
});

cliTest('renders Pi JSON events', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    const events = [
        { type: 'system', subtype: 'init', model: 'tiiny' },
        { type: 'system', subtype: 'api_retry',
            attempt: 1, max_retries: 2, error: 'temporary' },
        { type: 'assistant', message: { content: [
            { type: 'text', text: 'hello' },
            { type: 'tool_use', name: 'git', input: { x: 1 } },
        ] } },
        { type: 'user', message: { content: [{ type: 'tool_result' }] } },
        { type: 'result', subtype: 'success' },
    ];
    f.stub('pi', `
        for (const event of ${JSON.stringify(events)}) {
            console.log(JSON.stringify(event));
        }
    `);
    const result = f.run(['1']);
    result.status(0);
    for (const text of ['session start (tiiny)', 'retry 1/2', 'hello',
        'tool git:', 'tool result', 'session success']) result.text(text);
});

cliTest('reports missing assistant terminal output', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    f.stub('pi', `console.log(JSON.stringify({
        type: 'result', subtype: 'success',
    }));`);
    const result = f.run(['1']);
    result.status(0);
    result.text('missing assistant terminal output');
});

for (const subtype of ['error', 'aborted']) {
    cliTest(`reports Pi terminal outcome: ${subtype}`, (t, f) => {
        f.stories([{ id: 'todo', title: 'Todo' }]);
        loopStub(f, { text: 'failed', subtype });
        const result = f.run(['1']);
        result.status(0);
        result.text(`Pi terminal outcome: ${subtype}`);
    });
}

cliTest('ignores COMPLETE while tasks remain', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo', passes: false }]);
    loopStub(f, { text: '<promise>COMPLETE</promise>' });
    const result = f.run(['1']);
    result.status(0);
    result.text('ignoring COMPLETE');
});

cliTest('a new commit counts as progress', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    loopStub(f);
    const result = f.run(['1'], { PI_MODE: 'commit' });
    result.status(0);
    result.text('Progress (commits:');
});

cliTest('dirty files stall and stale Wrangler state is cleaned', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    loopStub(f);
    const result = f.run(['4']);
    result.status(2);
    result.text('No progress this session (stall 4/4)');
    const state = join(f.repo, '.wrangler/state/v3');
    mkdirSync(state, { recursive: true });
    f.run(['3']).status(0);
    t.ok(!existsSync(state), 'Wrangler state was cleaned');
});

cliTest('three failed sessions stop with status 4', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    loopStub(f);
    const result = f.run(['3'], { PI_MODE: 'fail' });
    result.status(4);
    result.text('Failed 3 consecutive Pi sessions');
});

cliTest('a later successful run reaches its iteration limit', (t, f) => {
    f.stories([{ id: 'todo', title: 'Todo' }]);
    loopStub(f);
    f.run(['1'], { PI_MODE: 'fail' }).status(0);
    const result = f.run(['1']);
    result.status(0);
    result.text('Reached MAX_ITERATIONS=1');
});

cliTest('reports sessions completing multiple stories', (t, f) => {
    f.stories([{ id: 'one', title: 'One' }, { id: 'two', title: 'Two' }]);
    loopStub(f);
    const result = f.run(['1'], { PI_MODE: 'complete_two' });
    result.status(0);
    result.text('completed more than one task');
});

function cliTest (name, body) {
    test(name, (t) => {
        const root = mkdtempSync(join(tmpdir(), 'ralph-tiiny-cli.'));
        const repo = join(root, 'work repo');
        const bin = join(root, 'bin');
        const calls = join(root, 'calls');
        const unexpected = join(root, 'unexpected');
        const env = {
            ...process.env,
            PATH: bin,
            TMPDIR: root,
            CALLS: calls,
            UNEXPECTED_CALLS: unexpected,
            GIT_CONFIG_NOSYSTEM: '1',
            GIT_CONFIG_GLOBAL: '/dev/null',
            GIT_AUTHOR_NAME: 'CLI Test',
            GIT_AUTHOR_EMAIL: 'cli-test@example.invalid',
            GIT_COMMITTER_NAME: 'CLI Test',
            GIT_COMMITTER_EMAIL: 'cli-test@example.invalid',
        };
        for (const key of [
            'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
        ]) {
            delete env[key];
        }
        const fixture = {
            repo, bin, env,
            write(path, content) {
                writeFileSync(join(this.repo, path), content);
            },
            stories(userStories) {
                this.write('specs/prd.json', JSON.stringify({ userStories }));
            },
            remove(path) {
                rmSync(path, { recursive: true, force: true });
            },
            stub(command, source) {
                this.remove(join(bin, command));
                writeFileSync(join(bin, command),
                    `#!${process.execPath}\n${source}\n`, { mode: 0o755 });
            },
            git(...args) {
                const result = spawnSync(executables.git, args, {
                    cwd: this.repo, env, encoding: 'utf8',
                });
                if (result.error) throw result.error;
                if (result.status !== 0) {
                    throw new Error(`git failed: ${result.stderr}`);
                }
            },
            run(args = [], overrides = {}) {
                const modelIndex = args.findIndex((arg) =>
                    arg === '--model' || arg === '-m');
                const result = spawnSync(executables.bash,
                    [runner, ...args], {
                        cwd: this.repo,
                        env: {
                            ...env,
                            TIINY_STUB_MODEL: modelIndex < 0
                                ? 'test/model' : args[modelIndex + 1] || '',
                            TIINY_STUB_MODE: 'one',
                            PI_MODE: 'noop',
                            ...overrides,
                        },
                        encoding: 'utf8',
                        timeout: 15000,
                    });
                if (result.error) throw result.error;
                const output = result.stdout + result.stderr;
                return {
                    status(code) {
                        t.equal(result.status, code,
                            `exit ${code} (got ${result.status})`);
                        if (result.status !== code) t.comment(output);
                    },
                    text(value) {
                        t.ok(output.includes(value), `output: ${value}`);
                        if (!output.includes(value)) t.comment(output);
                    },
                    config(iterations, turns, model) {
                        this.status(0);
                        this.text(`MAX_ITERATIONS=${iterations}`);
                        this.text(`MAX_TURNS_PER_SESSION=${turns}`);
                        this.text(`Requested model: ${model}`);
                    },
                };
            },
            calls() {
                return readFileSync(calls, 'utf8');
            },
        };
        try {
            mkdirSync(join(repo, 'specs'), { recursive: true });
            mkdirSync(bin);
            for (const command of commands) {
                symlinkSync(executables[command], join(bin, command));
            }
            fixture.git('init', '-q');
            fixture.write('PROMPT.md', 'test prompt\n');
            fixture.stories([]);
            fixture.stub('pi', `
                require('node:fs').appendFileSync(
                    process.env.UNEXPECTED_CALLS, 'pi\\n');
                process.exit(97);
            `);
            fixture.stub('tiiny', `
                if (JSON.stringify(process.argv.slice(2)) !==
                    JSON.stringify(['ls', '--json'])) {
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
            `);
            body(t, fixture);
            t.ok(!existsSync(unexpected), 'no unexpected external commands');
        } finally {
            rmSync(root, { recursive: true, force: true });
        }
    });
}

function loopStub(fixture, { text = 'done', subtype = 'success' } = {}) {
    fixture.stub('pi', `
        const fs = require('node:fs');
        const { execFileSync } = require('node:child_process');
        fs.appendFileSync(process.env.CALLS,
            process.argv.slice(2).join(' ') + '\\n' +
            fs.readFileSync(0, 'utf8'));
        const mode = process.env.PI_MODE;
        if (mode === 'fail') {
            console.log(JSON.stringify({ type: 'result', subtype: 'error' }));
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
            prd.userStories[1].passes = true;
            fs.writeFileSync('specs/prd.json', JSON.stringify(prd));
        }
        console.log(JSON.stringify({ type: 'assistant', message: {
            content: [{ type: 'text', text: ${JSON.stringify(text)} }],
        } }));
        console.log(JSON.stringify({
            type: 'result', subtype: ${JSON.stringify(subtype)},
        }));
    `);
}
