require 'yaml'
require 'tmpdir'
require 'open3'

root = File.expand_path('..', __dir__)
workflow = YAML.load_file(File.join(root, '.github/workflows/main.yml'))
action = YAML.load_file(File.join(root, '.github/actions/action.yml'))
steps = action.fetch('runs').fetch('steps')
scope_index = steps.index { |step| step['name'] == 'Check execution scope' }
token_index = steps.index { |step| step['id'] == 'app-token' }
raise 'Scope must precede authentication' unless scope_index < token_index
token = steps.fetch(token_index)
raise 'Unpinned token action' unless token.fetch('uses').match?(/\Aactions\/create-github-app-token@[a-f0-9]{40}\z/)
options = token.fetch('with')
raise 'Incorrect token scope' unless options['owner'] == 'inrage' && options['repositories'] == '${{ inputs.repository }}'
permissions = options.select { |key, _| key.start_with?('permission-') }
raise 'Excessive App permissions' unless permissions == { 'permission-contents' => 'write' }
raise 'Unexpected workflow permissions' unless workflow['permissions'] == { 'contents' => 'read' }

{ 'images' => 'docker-php', 'stability-tags' => '${{ matrix.script }}', 'tools' => 'docker-wordpress' }.each do |name, repository|
  job = workflow.fetch('jobs').fetch(name)
  raise 'Missing validation gate' unless job['needs'] == 'validate'
  invocation = job.fetch('steps').find { |step| step['uses'] == './.github/actions' }.fetch('with')
  raise 'Incorrect target repository' unless invocation['repository'] == repository
  raise 'Incorrect App credentials' unless invocation['app-client-id'] == '${{ vars.INRBOT_APP_CLIENT_ID }}' && invocation['app-private-key'] == '${{ secrets.INRBOT_APP_PRIVATE_KEY }}'
end
workflow.fetch('jobs').each_value do |job|
  checkout = job.fetch('steps').find { |step| step.fetch('uses', '').start_with?('actions/checkout@') }
  raise 'Checkout must be pinned without persisted credentials' unless checkout['uses'].match?(/@[a-f0-9]{40}\z/) && checkout.fetch('with')['persist-credentials'] == false
end

cases = [
  ['refs/heads/main', 'docker-php', true],
  ['refs/heads/main', 'docker-wordpress', true],
  ['refs/heads/feature', 'docker-php', false],
  ['refs/heads/main', 'docker-php,docker-wordpress', false],
  ['refs/heads/main', "docker-php\ndocker-wordpress", false],
  ['refs/heads/main', 'other/target', false],
  ['refs/heads/main', '', false]
]
cases.each do |ref, repository, allowed|
  _, _, result = Open3.capture3({ 'GITHUB_REF' => ref, 'REPOSITORY' => repository }, 'bash', '-euo', 'pipefail', '-c', steps.fetch(scope_index).fetch('run'))
  raise 'Incorrect execution scope' unless result.success? == allowed
end

Dir.mktmpdir('poller-identity-') do |dir|
  gh = File.join(dir, 'gh')
  output = File.join(dir, 'output')
  File.write(gh, "#!/bin/sh\ntest \"$*\" = 'api users/renamed-app[bot] --jq .id' || exit 1\nprintf '12345\\n'\n")
  File.chmod(0o755, gh)
  identity = steps.find { |step| step['id'] == 'bot' }.fetch('run')
  _, stderr, result = Open3.capture3({ 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'APP_SLUG' => 'renamed-app', 'GITHUB_OUTPUT' => output }, 'bash', '-euo', 'pipefail', '-c', identity)
  raise "Identity resolution failed: #{stderr}" unless result.success?
  raise 'Bot identity was hardcoded' unless File.read(output) == "name=renamed-app[bot]\nemail=12345+renamed-app[bot]@users.noreply.github.com\n"
end

puts "#{cases.length} scope cases and App identity checks passed"
