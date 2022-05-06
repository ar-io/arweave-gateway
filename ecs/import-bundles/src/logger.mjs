import winston from "winston";

export default winston.createLogger({
  level: "info",
  format: winston.format.combine(
    winston.format.timestamp({
      format: "YYYY-MM-DD HH:mm:ss",
    }),
    winston.format.errors({ stack: true }),
    winston.format.splat(),
    winston.format.json()
  ),
  defaultMeta: { service: "import-bundles" },
  transports: new winston.transports.Console({
    format: winston.format.simple(),
  }),
});
