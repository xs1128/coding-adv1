<script setup lang="ts">
// One horizontal bar split into shares of GPU kernel time. parts: [{ label, pct, color }]
defineProps<{ title: string; parts: { label: string; pct: number; color: string; dark?: boolean }[] }>()
</script>

<template>
  <div class="mb-5">
    <div class="text-[15px] font-semibold mb-1.5" style="color:#141B2D">{{ title }}</div>
    <div class="flex w-full h-12 gap-[2px]">
      <div v-for="p in parts" :key="p.label" :title="`${p.label}: ${p.pct} %`"
           class="h-full flex items-center px-2 overflow-hidden whitespace-nowrap text-[13px] first:rounded-l last:rounded-r"
           :style="{ width: p.pct + '%', background: p.color, color: p.dark ? '#F5F3EE' : '#141B2D' }">
        {{ p.pct >= 8 ? `${p.label} ${p.pct} %` : `${p.pct} %` }}
      </div>
    </div>
  </div>
</template>
