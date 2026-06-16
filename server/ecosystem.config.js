module.exports = {
  apps: [{
    name: 'gps-tracker-server',
    script: 'app.js',
    restart_delay: 3000,
    max_restarts: 10,
    watch: false,
    env: { NODE_ENV: 'production' }
  }]
};
