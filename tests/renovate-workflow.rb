require 'yaml'
require 'tmpdir'
require 'open3'

workflow = YAML.load_file(File.join(__dir__, '../.github/workflows/renovate-wordpress.yml'))
steps = workflow.fetch('jobs').fetch('renovate').fetch('steps')
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
