<template>
  <div
    v-if="$nav.currentPage > 1"
    class="absolute bottom-3 left-0 right-0 text-center slidev-page-num"
    style="font-size: 0.8rem; color: #777"
  >
    {{ $nav.currentPage }}
  </div>
</template>
