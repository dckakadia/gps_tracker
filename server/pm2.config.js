module.exports = {
  apps: [
    {
      name: 'gps-backend',
      script: 'app.js',
      cwd: __dirname,
      watch: false,
      env_production: {
        NODE_ENV: 'production',
      },
      autorestart: true,
      max_restarts: 10,
      restart_delay: 5000,
    },
  ],
};
