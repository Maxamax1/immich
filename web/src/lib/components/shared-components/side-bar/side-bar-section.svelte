<script lang="ts">
  import { clickOutside } from '$lib/actions/click-outside';
  import { focusTrap } from '$lib/actions/focus-trap';
  import { menuButtonId } from '$lib/components/shared-components/navigation-bar/navigation-bar.svelte';
  import { mobileDevice } from '$lib/stores/mobile-device.svelte';
  import { isSidebarOpen } from '$lib/stores/side-bar.svelte';
  import { onMount, type Snippet } from 'svelte';

  interface Props {
    children?: Snippet;
  }

  let { children }: Props = $props();

  onMount(() => {
    closeSidebar();
  });

  const closeSidebar = () => {
    isSidebarOpen.value = mobileDevice.isFullSidebar;
  };

  const isHidden = $derived(!isSidebarOpen.value && !mobileDevice.isFullSidebar);
  const isExpanded = $derived(isSidebarOpen.value && !mobileDevice.isFullSidebar);

  const handleClickOutside = () => {
    if (!isSidebarOpen.value) {
      return;
    }
    closeSidebar();
    if (isHidden) {
      document.querySelector<HTMLButtonElement>(`#${menuButtonId}`)?.focus();
    }
  };
</script>

<svelte:window onresize={closeSidebar} />
<section
  id="sidebar"
  tabindex="-1"
  class="immich-scrollbar relative z-10 w-0 sidebar:w-[16rem] overflow-y-auto overflow-x-hidden bg-immich-bg pt-8 transition-all duration-200 dark:bg-immich-dark-bg"
  class:shadow-2xl={isExpanded}
  class:dark:border-r-immich-dark-gray={isExpanded}
  class:border-r={isExpanded}
  class:w-[min(100vw,16rem)]={isSidebarOpen.value}
  inert={isHidden}
  use:clickOutside={{ onOutclick: handleClickOutside, onEscape: handleClickOutside }}
  use:focusTrap={{ active: isExpanded }}
>
  <div class="pr-6 flex flex-col gap-1 h-max min-h-full">
    {@render children?.()}
  </div>
</section>
