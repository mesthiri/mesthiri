#!/usr/bin/env node
// Validate every ```mermaid block in the given Markdown files.
//
// Both steps matter: parse catches syntax, render catches things parse does
// not — classDef/class errors, bad shape syntax, unknown directives. A broken
// diagram fails silently on GitHub and reads as a missing section, so this is
// the check CLAUDE.md asks for before committing docs/architecture.md.
//
//   npm i --no-save mermaid jsdom
//   node scripts/check-diagrams.mjs            # defaults to every .md under docs/
//   node scripts/check-diagrams.mjs docs/architecture.md
//
// Exits non-zero if any block fails.

import fs from 'node:fs'
import path from 'node:path'

const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : walk('docs')

// Recursive, so docs/guide/*.md is covered. A symlinked directory
// (docs/assets) is not a directory to Dirent, so it is skipped.
function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const p = path.join(dir, e.name)
    return e.isDirectory() ? walk(p) : e.name.endsWith('.md') ? [p] : []
  })
}

let JSDOM
try {
  ({ JSDOM } = await import('jsdom'))
} catch {
  console.error('missing dependencies. run:\n\n  npm i --no-save mermaid jsdom\n')
  process.exit(2)
}

// jsdom setup. Four things are load-bearing and each fails differently:
const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true })
global.window = dom.window
global.document = dom.window.document
// 1. `navigator` is a getter-only global on Node >= 21, so plain assignment
//    throws "Cannot set property navigator".
Object.defineProperty(global, 'navigator', { value: dom.window.navigator, configurable: true })
// 2. jsdom implements no layout, so SVGElement#getBBox does not exist. Without
//    this stub EVERY render throws, including blocks that are perfectly fine —
//    which looks like "render cannot run here" rather than a missing stub.
dom.window.SVGElement.prototype.getBBox = () => ({ x: 0, y: 0, width: 100, height: 20 })
// 3. Sequence diagrams reach for a bare CSSStyleSheet global.
global.CSSStyleSheet = dom.window.CSSStyleSheet

// 4. mermaid binds its bundled DOMPurify to `window` at *import* time, so it
//    must be imported after the globals above exist. Import it at the top of
//    the file instead and every block fails with "DOMPurify.sanitize is not a
//    function" — which reads like a broken dependency rather than an ordering
//    mistake. This is why the import is down here.
let mermaid
try {
  mermaid = (await import('mermaid')).default
} catch {
  console.error('missing dependencies. run:\n\n  npm i --no-save mermaid jsdom\n')
  process.exit(2)
}

mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' })

let checked = 0
let failed = 0

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8')
  const blocks = [...src.matchAll(/```mermaid\n([\s\S]*?)```/g)]
  if (!blocks.length) continue

  console.log(`\n${file}`)
  for (const [i, m] of blocks.entries()) {
    const code = m[1]
    // Line number of the fence, so a failure points somewhere useful.
    const line = src.slice(0, m.index).split('\n').length
    const label = `  block ${i + 1} (line ${line})`
    checked++

    // 3. mermaid logs its own parse errors to console.error before throwing;
    //    silence it so our report is the only output, then restore.
    const realError = console.error
    console.error = () => {}
    try {
      await mermaid.parse(code)
      const { svg } = await mermaid.render(`d${checked}`, code)
      console.error = realError
      console.log(`${label}: ok (${svg.length} bytes svg)`)
    } catch (e) {
      console.error = realError
      failed++
      console.log(`${label}: FAILED\n      ${String(e.message).split('\n').slice(0, 3).join('\n      ')}`)
    }
  }
}

console.log(
  failed
    ? `\n${failed} of ${checked} diagram(s) failed`
    : `\nall ${checked} diagram(s) parse and render clean`
)
process.exit(failed ? 1 : 0)
