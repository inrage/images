require 'yaml'
require 'tmpdir'
require 'open3'

workflow = YAML.load_file(File.join(__dir__, '../.github/workflows/renovate-wordpress.yml'))
preflight = workflow.fetch('jobs').fetch('renovate').fetch('steps').find { |step| step['name'] == 'Check access and scope' }.fetch('run')
cases = [
  ['inrage/*', 'simulate', 'refs/heads/main', 'fixture-token', true],
  ['inrage/audilab', 'update', 'refs/heads/main', 'fixture-token', true],
  ['inrage/example-site_2.0', 'simulate', 'refs/heads/feature', 'fixture-token', true],
  ['inrage/*', 'configure-notifier', 'refs/heads/main', 'fixture-token', true],
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
    env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'GH_CALLS' => calls, 'REPOSITORY_FILTER' => filter, 'MODE' => mode, 'GITHUB_REF' => ref, 'GH_TOKEN' => token }
    _, stderr, status = Open3.capture3(env, 'bash', '--noprofile', '--norc', '-euo', 'pipefail', '-c', preflight)
    raise "Unexpected result for #{[filter, mode, ref].inspect}: #{stderr}" unless status.success? == allowed
    raise 'Rejected input reached GitHub' if !allowed && File.exist?(calls)
    raise 'Accepted input skipped access checks' if allowed && !File.exist?(calls)
  end
end

puts "#{cases.length} preflight cases passed"
