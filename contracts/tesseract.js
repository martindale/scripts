'use strict';

async function main () {
  constructor (settings = {}) {
    super(settings);

    this.settings = Object.assign({
      name: '@portal/tesseract'
    }, this.settings, settings);

    return this;
  }
}

module.exports = main();
