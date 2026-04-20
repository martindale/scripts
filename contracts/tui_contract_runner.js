'use strict';

/**
 * Fabric TUI document: minimal contract lifecycle for exercising `@fabric/core`
 * in the Fabric CLI / TUI (load as a document first).
 *
 * Pattern matches upstream contract programs (e.g. `contracts/mount.js`,
 * `contracts/setup.js`): export a single async `OP_*` function; the host binds
 * `this` with `environment`, `program`, etc.
 *
 * @see https://raw.githubusercontent.com/martindale/fabric/master/CONTRACTS.md
 */

const Contract = require('@fabric/core/types/contract');

/**
 * @param {object} [command] - Optional payload from the TUI (args, flags, …).
 * @returns {Promise<string>} JSON result for the TUI transcript.
 */
async function OP_TUI_CONTRACT (command = {}) {
  const name =
    (command && (command.name || command.contractName)) ||
    'TUIContractRunner';

  const contract = new Contract({
    name,
    state: {
      name,
      status: 'PAUSED',
      actors: [],
      balances: {},
      constraints: {},
      signatures: [],
      tui: {
        loadedAt: new Date().toISOString(),
        command
      }
    }
  });

  contract.on('log', (line) => {
    console.log('[FABRIC:TUI_CONTRACT]', line);
  });

  contract.on('message', (message) => {
    console.log('[FABRIC:TUI_CONTRACT]', 'message', message && message.type);
  });

  contract.on('commit', (payload) => {
    console.log('[FABRIC:TUI_CONTRACT]', 'commit', payload && payload.created);
  });

  contract.start();
  contract.commit();

  const dryRun = Boolean(command && command.dryRun);
  const wantDeploy =
    Boolean(command && command.deploy) ||
    process.env.FABRIC_TUI_CONTRACT_DEPLOY === '1';
  const wantExecute =
    !dryRun &&
    (Boolean(command && command.execute) ||
      process.env.FABRIC_TUI_CONTRACT_EXECUTE === '1');

  if (wantDeploy) {
    contract.deploy();
  }

  if (wantExecute) {
    contract.execute();
  }

  const summary = {
    type: 'TUIContractRunner',
    name: contract.settings.name,
    status: contract.state && contract.state.status,
    actor: contract.actor && contract.actor.id,
    dryRun,
    deployed: wantDeploy,
    executed: wantExecute
  };

  return JSON.stringify(summary, null, 2);
}

module.exports = OP_TUI_CONTRACT;
