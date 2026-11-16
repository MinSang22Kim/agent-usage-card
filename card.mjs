import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';

const agents = [
  { id: 'claude', label: 'Claude Code', color: '#FFB18D' },
  { id: 'codex', label: 'Codex', color: '#79E3CF' },
];
const dateFormat = new Intl.DateTimeFormat('en-CA', { dateStyle: 'short' });
const numberFormat = new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 });

function calendarDays(end) {
  return Array.from({ length: 7 }, (_, index) => {
    const day = new Date(end);
    day.setDate(day.getDate() - 6 + index);
    return dateFormat.format(day);
  });
}

function sampleReport(days) {
  return {
    daily: days.map((period, index) => ({
      period,
      agents: [
        { agent: 'claude', totalTokens: [25, 16, 0, 21, 18, 8, 24][index] * 10000 },
        { agent: 'codex', totalTokens: [14, 0, 19, 13, 16, 0, 31][index] * 10000 },
      ],
    })),
  };
}

function localReport() {
  const args = ['--yes', '--package=ccusage@20.0.51', '--',
    'ccusage', 'daily', '--last', '7', '--timezone', 'local', '--by-agent', '--offline', '--no-cost', '--json'];
  try {
    // Windows npm ships its launcher as a .cmd file. All shell arguments are fixed.
    const output = process.platform === 'win32'
      ? execFileSync('cmd.exe', ['/d', '/s', '/c', ['npx.cmd', ...args].join(' ')], options())
      : execFileSync('npx', args, options());
    return JSON.parse(output);
  } catch {
    throw new Error('Could not read a ccusage report. Check that npm is available and local CLI usage logs exist, or run with --demo.');
  }
}

function options() {
  return { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 180000, maxBuffer: 16 * 1024 * 1024 };
}

function summarize(report, days) {
  if (!Array.isArray(report.daily)) throw new Error('Expected a ccusage daily report.');
  const usage = days.map(() => [0, 0]);
  for (const row of report.daily) {
    const index = days.indexOf(row.period);
    if (index === -1) continue;
    if (!Array.isArray(row.agents)) throw new Error('Expected a per-agent breakdown.');
    for (const entry of row.agents) {
      const agent = agents.findIndex(({ id }) => id === entry.agent);
      if (agent === -1) continue;
      if (!Number.isSafeInteger(entry.totalTokens) || entry.totalTokens < 0) {
        throw new Error('Invalid token count in the usage report.');
      }
      usage[index][agent] += entry.totalTokens;
    }
  }
  return usage;
}

function render(usage, days, demo) {
  const totals = agents.map((_, i) => usage.reduce((total, day) => total + day[i], 0));
  const total = totals[0] + totals[1];
  const peak = Math.max(1, ...usage.map(([a, b]) => a + b));
  const cards = agents.map(({ label, color }, index) => {
    const x = 28 + index * 270;
    const active = usage.filter(day => day[index] > 0).length;
    const share = total ? Math.round(100 * totals[index] / total) : 0;
    return `<g transform="translate(${x},94)">
  <rect width="254" height="79" rx="12" fill="#1A2739" />
  <circle cx="17" cy="18" r="4" fill="${color}" />
  <text x="29" y="22" class="label">${label}</text>
  <text x="15" y="49" class="value">${numberFormat.format(totals[index])}<tspan class="small"> tokens</tspan></text>
  <text x="15" y="67" class="small">${active}/7 active days · ${share}% of tokens</text>
</g>`;
  }).join('\n');
  const bars = usage.map((day, i) => {
    const x = 47 + i * 77;
    let y = 269;
    const segments = day.map((count, j) => {
      const height = count / peak * 64;
      y -= height;
      return height > 0 ? `<rect x="${x}" y="${y.toFixed(2)}" width="48" height="${height.toFixed(2)}" fill="${agents[j].color}" />` : '';
    }).join('');
    return `<rect x="${x}" y="205" width="48" height="64" rx="5" fill="#1A2739" />${segments}<text x="${x + 24}" y="288" text-anchor="middle" class="small">${days[i].slice(5)}</text>`;
  }).join('\n');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="580" height="314" viewBox="0 0 580 314" role="img" aria-labelledby="title desc">
<title id="title">Agent Usage Card${demo ? ' (sample data)' : ''}</title>
<desc id="desc">Claude Code: ${totals[0]} tokens. Codex: ${totals[1]} tokens. Seven days ending ${days.at(-1)}.</desc>
<style>
  text { font-family: system-ui, -apple-system, Segoe UI, sans-serif; fill: #F0F5FF; }
  .title { font-weight: 720; font-size: 27px; }
  .label { font-size: 13px; font-weight: 650; }
  .value { font-size: 24px; font-weight: 720; }
  .small { fill: #AABAD1; font-size: 12px; font-weight: 500; }
</style>
<rect x="0.5" y="0.5" width="579" height="313" rx="17" fill="#111B2B" stroke="#33465E" />
<text x="28" y="45" class="title">Agent Usage</text>
<text x="28" y="69" class="small">${days[0]} to ${days.at(-1)} · local dates${demo ? ' · Sample data' : ''}</text>
${cards}
<text x="28" y="194" class="label">Daily tokens</text>
${bars}
</svg>
`;
}

try {
  const { values } = parseArgs({
    options: { demo: { type: 'boolean' }, out: { type: 'string', default: 'agent-usage.svg' } },
  });
  const days = calendarDays(values.demo ? new Date(2026, 10, 16, 12) : new Date());
  const report = values.demo ? sampleReport(days) : localReport();
  writeFileSync(values.out, render(summarize(report, days), days, values.demo), 'utf8');
  console.log(`Wrote ${values.out}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
