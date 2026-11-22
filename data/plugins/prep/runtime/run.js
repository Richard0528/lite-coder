"use strict";

const fs = require("fs");
const vm = require("vm");
const path = require("path");

require("./prelude.js");

const file = process.argv[2];
if (!file) {
  console.error("usage: node run.js solution.js");
  process.exit(2);
}

const source = fs.readFileSync(file, "utf8");
// The lookup runs in the same script, so const/let solution functions are visible.
const wrapped = source + `
;globalThis.__prepLookup = function (name) {
  try {
    if (typeof Solution === "function") {
      const obj = new Solution();
      if (typeof obj[name] === "function") return obj[name].bind(obj);
    }
  } catch (err) {}
  try {
    const fn = eval(name);
    if (typeof fn === "function") return fn;
  } catch (err) {}
  if (typeof globalThis[name] === "function") return globalThis[name];
};
`;
try {
  vm.runInThisContext(wrapped, { filename: path.basename(file) });
} catch (err) {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
}

if (process.env.PREP_SPEC) {
  try {
    const spec = JSON.parse(fs.readFileSync(process.env.PREP_SPEC, "utf8"));
    runExamples(spec);
  } catch (err) {
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }
}
