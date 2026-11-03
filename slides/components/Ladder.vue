<script setup lang="ts">
// Median step time at 1 GPU after each kept rung. Each value is the "new" arm of that rung's own same-node A/B
// (job ids in docs/ladder.md and report.md); different nodes differ by about 1 %.
const rungs = [
  { name: 'v5.7.0', ms: 77.06, kind: 'base', note: 'original' },
  { name: 'P1', ms: 75.98, kind: 'p4', note: 'CBC async' },
  { name: 'K4b', ms: 70.42, kind: 'p4', note: 'one-file Riemann build' },
  { name: 'K2', ms: 62.99, kind: 'p4', note: 'WENO register cap' },
  { name: 'P3', ms: 61.79, kind: 'p4', note: 'async per-stage kernels' },
  { name: 'P4', ms: 60.38, kind: 'p4', note: '10-31 report' },
  { name: 'P7', ms: 45.10, kind: 'new', note: 'leaner copies' },
  { name: 'P11', ms: 42.04, kind: 'new', note: 'merged steps' },
  { name: 'P12', ms: 37.71, kind: 'new', note: 'WENO5 inside HLLC' },
  { name: 'P13', ms: 36.83, kind: 'new', note: 'flux slabs' },
  { name: 'P14', ms: 36.24, kind: 'new', note: 'fluxes into RK update' },
  { name: 'P17', ms: 35.90, kind: 'new', note: 'load ahead' },
  { name: 'P18', ms: 34.51, kind: 'new', note: 'load ahead in RK' },
  { name: 'P19', ms: 33.12, kind: 'new', note: 'direct slab reads' },
  { name: 'P20', ms: 29.63, kind: 'new', note: 'state slab, no self-copy' },
  { name: 'P21', ms: 28.27, kind: 'final', note: 'boundary work (686551)' },
]
const max = 77.06
const H = 300
const color = { base: '#8A93A6', p4: '#7FA6E8', new: '#2F6FDB', final: '#D9622B' } as Record<string, string>
</script>

<template>
  <div class="flex items-end gap-1.5 w-full" :style="{ height: H + 60 + 'px' }">
    <div v-for="r in rungs" :key="r.name" class="flex-1 flex flex-col items-center justify-end h-full">
      <div class="text-[13px] tabular-nums mb-1" style="color:#3D4556">{{ r.ms.toFixed(1) }}</div>
      <div :title="`${r.name}: ${r.ms} ms — ${r.note}`" class="w-full rounded-t"
           :style="{ height: (r.ms / max) * H + 'px', background: color[r.kind] }" />
      <div class="text-[13px] mt-1 font-mono" style="color:#141B2D">{{ r.name }}</div>
    </div>
  </div>
  <div class="flex gap-6 mt-3 text-[13px]" style="color:#3D4556">
    <span><span class="inline-block w-3 h-3 rounded-sm mr-1" style="background:#8A93A6" />v5.7.0</span>
    <span><span class="inline-block w-3 h-3 rounded-sm mr-1" style="background:#7FA6E8" />by the 10-31 report (P1–P4)</span>
    <span><span class="inline-block w-3 h-3 rounded-sm mr-1" style="background:#2F6FDB" />after it (P7–P20)</span>
    <span><span class="inline-block w-3 h-3 rounded-sm mr-1" style="background:#D9622B" />P21, today’s version</span>
  </div>
</template>
