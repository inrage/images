require 'yaml'
require 'tmpdir'
require 'open3'

workflow = YAML.load_file(File.join(__dir__, '../.github/workflows/renovate-wordpress.yml'))
steps = workflow.fetch('jobs').fetch('renovate').fetch('steps')
job = workflow.fetch('jobs').fetch('renovate')
triggers = workflow.fetch('on', workflow[true])
raise 'Reconciliation must run hourly' unless triggers.fetch('schedule') == [{ 'cron' => '37 * * * *' }]
raise 'Only dispatches and reconciliation may run Renovate' unless job['if'] == "github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'"
raise 'Reconciliation must retain serialized runs' unless job.fetch('concurrency') == { 'group' => 'renovate-wordpress', 'cancel-in-progress' => false }
raise 'Scheduled mode must explicitly be update' unless job.fetch('env').fetch('MODE') == "${{ github.event_name == 'schedule' && 'update' || inputs.mode }}"
raise 'Scheduled discovery must stay in inrage' unless job.fetch('env').fetch('REPOSITORY_FILTER') == "${{ github.event_name == 'schedule' && 'inrage/*' || inputs.repository_filter }}"
scope_index = steps.index { |step| step['name'] == 'Check execution scope' }
token_index = steps.index { |step| step['id'] == 'app-token' }
access_index = steps.index { |step| step['name'] == 'Check GitHub App access' }
raise 'Scope must be checked before token creation' unless scope_index < token_index && token_index < access_index
token_step = steps.fetch(token_index)
raise 'The token action must be pinned' unless token_step.fetch('uses').match?(/\Aactions\/create-github-app-token@[a-f0-9]{40}\z/)
token_options = token_step.fetch('with')
raise 'Token discovery must stay in inrage without a repository inventory' unless token_options['owner'] == 'inrage' && !token_options.key?('repositories')
raise 'The Renovate token must not control Actions' if token_options.key?('permission-actions')
preflight = [steps.fetch(scope_index).fetch('run'), steps.fetch(access_index).fetch('run')].join("\n")
cases = [
  ['inrage/*', 'simulate', 'refs/heads/main', 'fixture-token', true],
  ['inrage/audilab', 'update', 'refs/heads/main', 'fixture-token', true],
  ['inrage/example-site_2.0', 'simulate', 'refs/heads/feature', 'fixture-token', true],
  ['inrage/*', 'configure-notifier', 'refs/heads/main', 'fixture-token', false],
  ['inrage/*,other-org/*', 'update', 'refs/heads/main', 'fixture-token', false],
  ["inrage/*\nother-org/*", 'update', 'refs/heads/main', 'fixture-token', false],
  ['other-org/*', 'update', 'refs/heads/main', 'fixture-token', false],
  ['inrage/', 'update', 'refs/heads/main', 'fixture-token', false],
  ['inrage/*', 'update', 'refs/heads/feature', 'fixture-token', false],
  ['inrage/*', 'configure-notifier', 'refs/heads/feature', 'fixture-token', false],
  ['inrage/*', 'unexpected', 'refs/heads/main', 'fixture-token', false],
  ['inrage/*', 'update', 'refs/heads/main', '', false]
]

Dir.mktmpdir('renovate-preflight-') do |dir|
  executable = File.join(dir, 'gh')
  calls = File.join(dir, 'calls')
  File.write(executable, "#!/bin/sh\nprintf '%s\\n' called >> \"$GH_CALLS\"\nprintf '%s\\n' ok\n")
  File.chmod(0o755, executable)
  cases.each do |filter, mode, ref, token, allowed|
    File.delete(calls) if File.exist?(calls)
    env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'GH_CALLS' => calls, 'REPOSITORY_FILTER' => filter, 'MODE' => mode, 'GITHUB_REF' => ref, 'GH_TOKEN' => token, 'APP_SLUG' => 'fixture-app' }
    _, stderr, status = Open3.capture3(env, 'bash', '--noprofile', '--norc', '-euo', 'pipefail', '-c', preflight)
    raise "Unexpected result for #{[filter, mode, ref].inspect}: #{stderr}" unless status.success? == allowed
    raise 'Rejected input reached GitHub' if !allowed && File.exist?(calls)
    raise 'Accepted input skipped access checks' if allowed && !File.exist?(calls)
  end
end

puts "#{cases.length} preflight cases passed"

policy_check = <<~'JS'
  import assert from 'node:assert/strict';
  import { readFileSync } from 'node:fs';
  import { runInNewContext } from 'node:vm';
  import { applyPackageRules } from '/usr/local/renovate/dist/util/package-rules/index.js';
  import { mergeChildConfig } from '/usr/local/renovate/dist/config/utils.js';

  const policy = JSON.parse(readFileSync('/config/renovate-wordpress.json', 'utf8'));
  const inherited = {
    automerge: true, automergeType: 'branch', automergeStrategy: 'squash', platformAutomerge: true, ignoreTests: true,
    packageRules: [{ matchPackageNames: ['*'], automerge: true, platformAutomerge: true, ignoreTests: true }],
  };
  let checked = 0;
  for (const manager of ['dockerfile', 'custom.regex']) {
    for (const packageName of ['inrage/docker-wordpress', 'inrage/docker-php']) {
      for (const updateType of ['digest', 'pinDigest', 'major', 'minor', 'patch', 'rollback', 'replacement']) {
        for (const currentValue of ['7.2', '8.3-redis', '8.4-frankenphp', '8.3.1', 'latest', 'latest-redis', '8', '8.4-unknown']) {
          const input = mergeChildConfig(mergeChildConfig(policy, inherited), {
            manager, packageName, depName: packageName, updateType, currentValue,
          });
          const actual = await applyPackageRules(input, 'automerge-policy');
          const allowed = packageName === 'inrage/docker-wordpress' && updateType === 'digest'
            && ['7.2', '8.3-redis', '8.4-frankenphp', '8.3.1'].includes(currentValue);
          const lateOverride = mergeChildConfig(actual, inherited);
          assert.equal(lateOverride.automerge, allowed, JSON.stringify({ manager, packageName, updateType, currentValue }));
          assert.equal(lateOverride.automergeType, 'pr');
          assert.equal(lateOverride.automergeStrategy, 'auto');
          assert.equal(lateOverride.platformAutomerge, false);
          assert.equal(lateOverride.ignoreTests, false);
          if (packageName !== 'inrage/docker-wordpress') assert.equal(actual.enabled, false);
          checked++;
        }
      }
    }
  }

  const githubSource = readFileSync('/usr/local/renovate/dist/modules/platform/github/index.js', 'utf8');
  const statusSource = githubSource.slice(githubSource.indexOf('async function getBranchStatus('), githubSource.indexOf('\nasync function getStatusCheck('));
  assert.match(statusSource, /^async function getBranchStatus\(/);
  const statusCases = [
    ['no checks', [], 'yellow'],
    ['CodeRabbit skipped', ['skipped'], 'green'],
    ['successful CI', ['success'], 'green'],
    ['successful CI and skipped review', ['success', 'skipped'], 'green'],
    ['pending CI', [null, 'skipped'], 'yellow'],
    ['failed CI', ['failure', 'skipped'], 'red'],
    ['cancelled CI', ['cancelled', 'skipped'], 'yellow'],
  ];
  for (const [name, conclusions, expected] of statusCases) {
    const getBranchStatus = runInNewContext(`${statusSource}\ngetBranchStatus`, {
      logger: { debug() {}, warn() {} }, config: { repository: 'inrage/example' },
      getStatus: async () => ({ state: 'pending', statuses: [] }),
      escapeHash: value => value, memCacheProvider: {},
      githubApi: { getJsonUnchecked: async () => ({ body: { check_runs: conclusions.map(conclusion => ({
        name, status: conclusion === null ? 'in_progress' : 'completed', conclusion,
      })) } }) },
    });
    assert.equal(await getBranchStatus('renovate-wordpress/wordpress-base-images', false), expected, name);
  }
  console.log(`${checked} native automerge policy cases and ${statusCases.length} native status cases passed`);
JS

root = File.expand_path('..', __dir__)
image = steps.find { |step| step['name'] == 'Update WordPress dependencies' }.fetch('run')[%r{ghcr.io/renovatebot/renovate@sha256:[a-f0-9]{64}}]
raise 'Native policy validation requires the pinned Renovate image' unless image
stdout, stderr, status = Open3.capture3('docker', 'run', '--rm', '-i', '--platform', 'linux/amd64', '--network', 'none', '--mount', "type=bind,source=#{root},target=/config,readonly", '--entrypoint', '/usr/local/renovate/node', image, '--input-type=module', stdin_data: policy_check)
raise "Native automerge policy validation failed: #{stdout}\n#{stderr}" unless status.success?
puts stdout
