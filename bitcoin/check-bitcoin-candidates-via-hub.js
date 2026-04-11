#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const { URL } = require('url');

function usage() {
  console.error('Usage: check-bitcoin-candidates-via-hub.js <scan-json> [hub-base-url]');
  console.error('');
  console.error('Examples:');
  console.error('  node check-bitcoin-candidates-via-hub.js ~/scan-results.json');
  console.error('  node check-bitcoin-candidates-via-hub.js ~/scan-results.json https://hub.example.com');
  console.error('');
  console.error('Environment:');
  console.error('  HUB_URL            default hub base URL (default http://127.0.0.1:8080)');
  console.error('  HUB_API_TOKEN      optional bearer token');
  console.error('  MAX_ADDRESSES      cap address checks (default 500)');
  console.error('  MAX_XPUBS          cap xpub checks (default 100)');
  console.error('  OUTPUT_JSON        write report path (default <scan-json>.funds.json)');
}

function requestJson(urlString, token = '') {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const lib = url.protocol === 'https:' ? https : http;
    const req = lib.request({
      method: 'GET',
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: `${url.pathname}${url.search}`,
      headers: {
        Accept: 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {})
      }
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        if (!body) return resolve({});
        try {
          const parsed = JSON.parse(body);
          if (res.statusCode >= 400) {
            return reject(new Error(`HTTP ${res.statusCode}: ${parsed.message || body}`));
          }
          return resolve(parsed);
        } catch (err) {
          return reject(new Error(`Invalid JSON from ${urlString}: ${err.message}`));
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function uniqStrings(values = []) {
  const out = [];
  const seen = new Set();
  for (const value of values) {
    const s = String(value || '').trim();
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 1 || args.includes('-h') || args.includes('--help')) {
    usage();
    process.exit(args.length < 1 ? 1 : 0);
  }

  const scanPath = path.resolve(args[0]);
  const hubBaseUrl = String(args[1] || process.env.HUB_URL || 'http://127.0.0.1:8080').replace(/\/+$/, '');
  const token = String(process.env.HUB_API_TOKEN || '');
  const maxAddresses = Math.max(1, Number(process.env.MAX_ADDRESSES || 500));
  const maxXpubs = Math.max(1, Number(process.env.MAX_XPUBS || 100));
  const outputPath = process.env.OUTPUT_JSON
    ? path.resolve(process.env.OUTPUT_JSON)
    : `${scanPath.replace(/\.json$/i, '')}.funds.json`;

  const raw = fs.readFileSync(scanPath, 'utf8');
  const scanData = JSON.parse(raw);
  const keys = scanData && scanData.keyCandidates ? scanData.keyCandidates : {};

  const addresses = uniqStrings(keys.addressLikeAny || []).slice(0, maxAddresses);
  const xpubs = uniqStrings(keys.xpubLike || []).slice(0, maxXpubs);

  console.error(`Checking ${addresses.length} addresses and ${xpubs.length} xpubs against ${hubBaseUrl}`);

  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    sourceScanJson: scanPath,
    hubBaseUrl,
    limits: { maxAddresses, maxXpubs },
    checked: {
      addresses: addresses.length,
      xpubs: xpubs.length
    },
    funded: {
      addresses: [],
      xpubs: []
    },
    errors: []
  };

  for (const address of addresses) {
    const url = `${hubBaseUrl}/services/bitcoin/addresses/${encodeURIComponent(address)}/balance`;
    try {
      const data = await requestJson(url, token);
      const sats = Number(data.balanceSats || 0);
      if (sats > 0) {
        report.funded.addresses.push({
          address,
          balanceSats: sats,
          balance: Number(data.balance || 0),
          network: data.network || null
        });
      }
    } catch (err) {
      report.errors.push({ type: 'address', value: address, error: err.message });
    }
  }

  for (let i = 0; i < xpubs.length; i++) {
    const xpub = xpubs[i];
    const walletId = `scan-xpub-${i + 1}`;
    const url = `${hubBaseUrl}/services/bitcoin/wallets/${encodeURIComponent(walletId)}?xpub=${encodeURIComponent(xpub)}`;
    try {
      const data = await requestJson(url, token);
      const sats = Number(data.balanceSats || 0);
      if (sats > 0) {
        report.funded.xpubs.push({
          xpub,
          walletId,
          balanceSats: sats,
          confirmedSats: Number(data.confirmedSats || 0),
          unconfirmedSats: Number(data.unconfirmedSats || 0),
          network: data.network || null
        });
      }
    } catch (err) {
      report.errors.push({ type: 'xpub', value: xpub, error: err.message });
    }
  }

  report.summary = {
    fundedAddressCount: report.funded.addresses.length,
    fundedXpubCount: report.funded.xpubs.length,
    totalFundedSats:
      report.funded.addresses.reduce((s, x) => s + Number(x.balanceSats || 0), 0) +
      report.funded.xpubs.reduce((s, x) => s + Number(x.balanceSats || 0), 0),
    errorCount: report.errors.length
  };

  fs.writeFileSync(outputPath, JSON.stringify(report, null, 2) + '\n', 'utf8');
  console.log(`Report written: ${outputPath}`);
  console.log(`Funded addresses: ${report.summary.fundedAddressCount}`);
  console.log(`Funded xpubs: ${report.summary.fundedXpubCount}`);
  console.log(`Total funded sats: ${report.summary.totalFundedSats}`);
  if (report.summary.errorCount > 0) {
    console.log(`Errors: ${report.summary.errorCount} (see report JSON)`);
  }
}

main().catch((err) => {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
});
