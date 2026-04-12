#!/usr/bin/env node

'use strict';

const settings = require('../settings/local');
const Filesystem = require('@fabric/core/types/filesystem');

async function main (input = {}) {
  const tesseract = new Filesystem();

  return this;
}

main(settings).catch((exception) => {
  console.error(exception);
}).then((output) => {
  console.log(output);
});
