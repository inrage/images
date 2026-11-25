module.exports = {
  ...require('./renovate-wordpress.json'),
  dryRun: 'full',
  hostRules: [
    { matchHost: 'api.github.com', enabled: false },
    { matchHost: 'api.github.com', readOnly: true, enabled: true },
  ],
};
