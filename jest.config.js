const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

// Every run in one zone, and one behind UTC: that is where `new Date("2026-09-24")` - midnight
// UTC - lands on the 23rd, so a board that formats a calendar day that way fails here rather
// than only for visitors in the Americas. Set before the workers start, which inherit it; a
// test file cannot move the zone itself, because Jest hands it a copy of process.env.
process.env.TZ = "America/Los_Angeles";

module.exports = {
  ...jestConfig,
  // "css" last, so c/boardTheme - a CSS-only module - resolves to its stylesheet while every
  // other c/ import still finds its .js first.
  moduleFileExtensions: [...jestConfig.moduleFileExtensions, "css"],
  setupFilesAfterEnv: [
    ...(jestConfig.setupFilesAfterEnv || []),
    "<rootDir>/jest-sa11y-setup.js"
  ],
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"]
};
