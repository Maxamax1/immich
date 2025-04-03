import { sidebarBreakpoint } from '$lib/components/shared-components/side-bar/side-bar-section.svelte';
import { MediaQuery } from 'svelte/reactivity';

const pointerCoarse = new MediaQuery('pointer:coarse');
const maxMd = new MediaQuery('max-width: 767px');
const sidebar = new MediaQuery(`min-width: ${sidebarBreakpoint}px`);

export const mobileDevice = {
  get pointerCoarse() {
    return pointerCoarse.current;
  },
  get maxMd() {
    return maxMd.current;
  },
  get sidebar() {
    return sidebar.current;
  },
};
