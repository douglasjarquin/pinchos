import { createCollapsedMenuController } from './collapsed-menu.js';

const initializeMenu = (root) => {
  const menuBar = root.querySelector('.menu-bar');
  const menuSurface = root.querySelector('[data-menu-surface]');
  const panel = root.querySelector('[data-example-panel]');
  const collapsedTrigger = root.querySelector('[data-collapsed-trigger]');
  const collapsedPanel = root.querySelector('[data-collapsed-panel]');
  const collapsedItems = root.querySelector('[data-collapsed-items]');
  const collapsedEmpty = root.querySelector('[data-collapsed-empty]');
  const expandAction = root.querySelector('[data-expand-action]');
  const collapseAction = panel?.querySelector('[data-collapse-action]');
  const triggers = [...root.querySelectorAll('[data-menu-item]')];
  const runAction = panel?.querySelector('[data-run-action]');
  const refreshAction = panel?.querySelector('[data-refresh-action]');
  const hideAction = panel?.querySelector('[data-hide-action]');
  const configuredActions = panel?.querySelector('[data-configured-actions]');
  const clickLink = panel?.querySelector('[data-click-link]');
  const noClick = panel?.querySelector('[data-no-click]');
  const summary = panel?.querySelector('[data-summary]');
  const failureDetails = panel?.querySelector('[data-failure-details]');
  const meta = panel?.querySelector('[data-item-meta]');
  const diagnostics = panel?.querySelector('[data-diagnostics]');
  const diagnosticsTrigger = diagnostics?.querySelector('summary');
  const diagnosticItem = panel?.querySelector('[data-diagnostic-item]');
  const diagnosticRefresh = panel?.querySelector('[data-diagnostic-refresh]');
  const diagnosticFormat = panel?.querySelector('[data-diagnostic-format]');
  const diagnosticClick = panel?.querySelector('[data-diagnostic-click]');
  const diagnosticError = panel?.querySelector('[data-diagnostic-error]');
  const diagnosticStale = panel?.querySelector('[data-diagnostic-stale]');
  const diagnosticHidden = panel?.querySelector('[data-diagnostic-hidden]');
  const feedback = panel?.querySelector('[data-feedback]');
  const emptyState = root.querySelector('[data-menu-empty]');
  const configPreview = root.closest('.product-visual')?.querySelector('[data-sample-config]');
  const initialConfig = configPreview?.textContent ?? '';

  if (!menuBar || !menuSurface || !panel || !collapsedTrigger || !collapsedPanel || !collapsedItems || !collapsedEmpty || !expandAction || !collapseAction || !runAction || !refreshAction || !hideAction || !configuredActions || !clickLink || !noClick || !summary || !failureDetails || !meta || !diagnostics || !diagnosticsTrigger || !diagnosticItem || !diagnosticRefresh || !diagnosticFormat || !diagnosticClick || !diagnosticError || !diagnosticStale || !diagnosticHidden || !feedback || !emptyState || triggers.length === 0) {
    return;
  }

  diagnostics.addEventListener('toggle', () => {
    diagnosticsTrigger.setAttribute('aria-expanded', String(diagnostics.open));
  });

  const states = new Map(
    triggers.map((trigger) => [trigger.dataset.menuItem, {
      failed: trigger.dataset.initialState === 'failed',
      refreshing: false,
      activity: null,
      hidden: trigger.dataset.hidden === 'true',
    }]),
  );
  const timers = new Map();
  const stateFor = (name) => states.get(name) ?? { failed: false, refreshing: false, activity: null, hidden: false };
  const visibleTriggers = () => triggers.filter((trigger) => !stateFor(trigger.dataset.menuItem).hidden);
  let activeName = visibleTriggers()[0]?.dataset.menuItem ?? triggers[0].dataset.menuItem;
  let panelOpen = false;
  let collapsed = false;
  let collapsedRootOpen = false;
  let diagnosticsVisible = false;
  let renderedActionName = null;

  const activeTrigger = () => triggers.find((trigger) => trigger.dataset.menuItem === activeName && !stateFor(activeName).hidden);

  const configuredActionData = (trigger) => {
    try {
      const actions = JSON.parse(trigger.dataset.actions ?? '[]');
      return Array.isArray(actions)
        ? actions.filter((action) => action && typeof action.title === 'string' && (action.kind === 'run' || action.kind === 'refresh'))
        : [];
    } catch {
      return [];
    }
  };

  const updateConfigPreview = () => {
    if (!configPreview) return;

    const hiddenNames = new Set(
      [...states]
        .filter(([, state]) => state.hidden)
        .map(([itemName]) => itemName),
    );
    let currentItemName = null;
    const lines = initialConfig.split('\n').map((line) => {
      const header = line.match(/^\[item\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]$/);
      if (header) {
        currentItemName = header[1] ?? header[2];
      } else if (line.startsWith('[')) {
        currentItemName = null;
      }

      if (currentItemName && hiddenNames.has(currentItemName) && /^hidden = (?:true|false)(\s*(?:#.*)?)$/.test(line)) {
        return line.replace(/^(hidden = )(?:true|false)/, '$1true');
      }
      return line;
    });
    configPreview.textContent = lines.join('\n');
  };

  const renderConfiguredActions = (trigger) => {
    configuredActions.replaceChildren();
    configuredActionData(trigger).forEach(({ title, kind }) => {
      const action = document.createElement('button');
      action.className = 'example-menu__action';
      action.type = 'button';
      action.setAttribute('role', 'menuitem');
      action.tabIndex = -1;
      action.dataset.configuredAction = kind;
      action.textContent = title;
      action.addEventListener('click', () => {
        if (activeName !== trigger.dataset.menuItem) return;
        startSimulation(activeName, kind === 'refresh' ? 'refresh' : 'action', kind === 'refresh');
      });
      configuredActions.append(action);
    });
  };

  const startSimulation = (itemName, activity, recover) => {
    const state = stateFor(itemName);
    if (state.refreshing || state.hidden) return;

    state.refreshing = true;
    state.activity = activity;
    updatePanel();
    const timer = window.setTimeout(() => {
      state.refreshing = false;
      state.activity = null;
      if (recover) state.failed = false;
      timers.delete(itemName);
      updatePanel();
    }, 450);
    timers.set(itemName, timer);
  };

  const updatePanel = () => {
    const visible = visibleTriggers();
    if (!visible.some((itemTrigger) => itemTrigger.dataset.menuItem === activeName)) {
      activeName = visible[0]?.dataset.menuItem ?? activeName;
    }
    const trigger = activeTrigger();
    menuBar.classList.toggle('menu-bar--collapsed', collapsed);
    menuSurface.classList.toggle('interactive-menu__surface--collapsed', collapsed);
    menuBar.setAttribute('aria-label', collapsed ? 'Collapsed sample pinchos menu bar' : 'Interactive sample pinchos menu bar');
    collapsedTrigger.hidden = !collapsed;
    collapsedTrigger.setAttribute('aria-expanded', String(collapsedRootOpen));
    collapsedPanel.hidden = !collapsedRootOpen;
    emptyState.hidden = collapsed || visible.length !== 0;

    triggers.forEach((itemTrigger) => {
      const isActive = itemTrigger === trigger;
      const itemState = stateFor(itemTrigger.dataset.menuItem);
      itemTrigger.hidden = collapsed || itemState.hidden;
      itemTrigger.setAttribute('aria-expanded', String(panelOpen && isActive));
      itemTrigger.dataset.state = itemState.refreshing ? 'running' : itemState.failed ? 'failed' : 'fresh';
      const itemDisplay = itemTrigger.querySelector('[data-item-display]');
      if (itemDisplay) itemDisplay.textContent = itemState.failed ? itemTrigger.dataset.displayValue : itemTrigger.dataset.value;
    });

    collapsedMenu.render();

    updateConfigPreview();

    if (!trigger) {
      panel.hidden = true;
      return;
    }

    const state = stateFor(activeName);
    const label = trigger.dataset.itemLabel ?? activeName;
    const value = trigger.dataset.value ?? '';
    const displayValue = state.failed ? trigger.dataset.displayValue : value;
    const interval = trigger.dataset.interval ?? '';
    const format = trigger.dataset.format || 'raw output';
    const clickCommand = trigger.dataset.clickCommand ?? '';
    const errorPolicy = trigger.dataset.errorPolicy || 'default';
    const staleAfter = trigger.dataset.staleAfter || 'not configured';
    const hidden = state.hidden;
    const stateText = state.refreshing
      ? state.activity === 'run' || state.activity === 'action' ? 'running…' : 'refreshing…'
      : state.failed
        ? 'failed · showing last good value'
        : 'updated just now';

    if (renderedActionName !== activeName) {
      renderConfiguredActions(trigger);
      renderedActionName = activeName;
    }

    panel.hidden = !panelOpen;
    diagnostics.hidden = !diagnosticsVisible;
    diagnosticsTrigger.setAttribute('aria-expanded', String(diagnostics.open));
    panel.dataset.state = state.refreshing ? 'running' : state.failed ? 'failed' : 'fresh';
    panel.setAttribute('aria-label', `${label} item submenu`);
    summary.textContent = `${displayValue} · ${stateText}`;
    meta.textContent = `Refresh: every ${interval} · Format: ${format}`;
    feedback.hidden = true;
    feedback.textContent = '';
    diagnosticItem.textContent = `[item.${activeName}]`;
    diagnosticRefresh.textContent = `Refresh: every ${interval}`;
    diagnosticFormat.textContent = `Format: ${format}`;
    diagnosticClick.textContent = clickCommand ? `Click: ${clickCommand}` : 'Click: not configured';
    diagnosticError.textContent = `On error: ${errorPolicy}`;
    diagnosticStale.textContent = `Stale after: ${staleAfter}`;
    diagnosticHidden.textContent = `Hidden: ${hidden ? 'yes' : 'no'}`;
    failureDetails.hidden = !state.failed;
    runAction.disabled = state.refreshing;
    runAction.textContent = state.refreshing && state.activity === 'run' ? `Running ${label}…` : `Run ${label}`;
    refreshAction.disabled = state.refreshing;
    refreshAction.textContent = state.refreshing && state.activity === 'refresh' ? 'Refreshing…' : 'Refresh Now';
    refreshAction.hidden = configuredActionData(trigger).some(({ kind }) => kind === 'refresh');
    hideAction.disabled = state.refreshing || hidden;
    configuredActions.querySelectorAll('[data-configured-action]').forEach((action) => {
      action.disabled = state.refreshing;
    });
    clickLink.hidden = !clickCommand;
    noClick.hidden = Boolean(clickCommand);
    collapseAction.textContent = collapsed ? 'Expand Pinchos' : 'Collapse Pinchos';

    if (clickCommand) {
      clickLink.href = trigger.dataset.clickUrl ?? '';
      clickLink.textContent = `Open ${label} usage page ↗`;
    } else {
      clickLink.removeAttribute('href');
    }

    const spokenValue = value.replace('🔋 ', '').replace('%', ' percent');
    trigger.setAttribute('aria-label', `${label}, ${spokenValue}${state.failed ? ', failed, showing last good value' : ', fresh'}`);
  };

  const focusFirstAction = () => {
    runAction.focus();
  };

  const openItem = (trigger, showDiagnostics) => {
    const nextName = trigger.dataset.menuItem;
    if (stateFor(nextName).hidden) return;
    if (nextName !== activeName) {
      activeName = nextName;
    }
    diagnosticsVisible = showDiagnostics;
    diagnostics.open = showDiagnostics;
    panelOpen = true;
    updatePanel();
  };

  const closeCollapsedRoot = () => {
    collapsedRootOpen = false;
    panelOpen = false;
    diagnosticsVisible = false;
    diagnostics.open = false;
    updatePanel();
    collapsedTrigger.focus();
  };

  const closePanel = () => {
    panelOpen = false;
    diagnosticsVisible = false;
    diagnostics.open = false;
    updatePanel();
  };

  const collapsedMenu = createCollapsedMenuController({
    collapsedItems,
    collapsedEmpty,
    visibleTriggers,
    stateFor,
    isCollapsed: () => collapsed,
    isRootOpen: () => collapsedRootOpen,
    isPanelOpen: () => panelOpen,
    activeName: () => activeName,
    expandAction,
    openItem: (trigger, showDiagnostics) => openItem(trigger, showDiagnostics),
    closeRoot: closeCollapsedRoot,
    focusFirstAction,
    focusDiagnostics: () => diagnosticsTrigger.focus(),
  });

  const visiblePanelItems = () => [...panel.querySelectorAll('[role="menuitem"]')]
    .filter((item) => !item.hidden && !item.disabled && item.getClientRects().length > 0);

  const updateMenuTabStops = (menu, target) => {
    menu.querySelectorAll('[role="menuitem"]').forEach((item) => {
      item.tabIndex = item === target ? 0 : -1;
    });
  };

  collapsedPanel.addEventListener('focusin', (event) => {
    const target = event.target;
    if (target instanceof HTMLElement && target.getAttribute('role') === 'menuitem') {
      updateMenuTabStops(collapsedPanel, target);
    }
  });

  panel.addEventListener('focusin', (event) => {
    const target = event.target;
    if (target instanceof HTMLElement && target.getAttribute('role') === 'menuitem') {
      updateMenuTabStops(panel, target);
    }
  });

  panel.addEventListener('keydown', (event) => {
    const target = event.target;
    if (!(target instanceof HTMLElement) || target.getAttribute('role') !== 'menuitem') return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const items = visiblePanelItems();
      const index = items.indexOf(target);
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      items[(index + delta + items.length) % items.length]?.focus();
    } else if (event.key === 'ArrowLeft' && collapsed) {
      event.preventDefault();
      closePanel();
      collapsedItems.querySelector(`[data-collapsed-item="${activeName}"]`)?.focus();
    }
  });

  expandAction.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      closeCollapsedRoot();
      return;
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const rows = [...collapsedItems.querySelectorAll('[data-collapsed-item]')];
    if (rows.length === 0) return;
    event.preventDefault();
    rows[event.key === 'ArrowDown' ? 0 : rows.length - 1]?.focus();
  });

  collapsedTrigger.addEventListener('click', () => {
    collapsedRootOpen = !collapsedRootOpen;
    panelOpen = false;
    diagnosticsVisible = false;
    diagnostics.open = false;
    updatePanel();
    if (collapsedRootOpen) collapsedItems.querySelector('[data-collapsed-item]')?.focus();
  });

  collapseAction.addEventListener('click', () => {
    if (collapsed) {
      collapsed = false;
      collapsedRootOpen = false;
      panelOpen = false;
      diagnosticsVisible = false;
      diagnostics.open = false;
      updatePanel();
      activeTrigger()?.focus();
      return;
    }
    collapsed = true;
    collapsedRootOpen = false;
    panelOpen = false;
    diagnosticsVisible = false;
    diagnostics.open = false;
    updatePanel();
    collapsedTrigger.focus();
  });

  expandAction.addEventListener('click', () => {
    collapsed = false;
    collapsedRootOpen = false;
    panelOpen = false;
    diagnosticsVisible = false;
    diagnostics.open = false;
    updatePanel();
    activeTrigger()?.focus();
  });

  triggers.forEach((trigger) => {
    trigger.addEventListener('keydown', (event) => {
      if (event.altKey && event.key === 'Enter') {
        event.preventDefault();
        openItem(trigger, true);
        diagnostics.querySelector('summary')?.focus();
        return;
      }
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        openItem(trigger, false);
        focusFirstAction();
      }
    });

    trigger.addEventListener('click', (event) => {
      openItem(trigger, event.altKey && event.button === 0);
      if (panelOpen && event.detail === 0) focusFirstAction();
    });
  });

  runAction.addEventListener('click', () => startSimulation(activeName, 'run', true));
  refreshAction.addEventListener('click', () => startSimulation(activeName, 'refresh', true));
  hideAction.addEventListener('click', () => {
    const current = stateFor(activeName);
    if (current.hidden) return;

    const nextTrigger = visibleTriggers().find((trigger) => trigger.dataset.menuItem !== activeName);
    current.hidden = true;
    current.refreshing = false;
    current.activity = null;
    panelOpen = false;
    collapsedRootOpen = collapsed;
    diagnosticsVisible = false;
    diagnostics.open = false;
    activeName = nextTrigger?.dataset.menuItem ?? activeName;
    updatePanel();
    if (collapsed) {
      (collapsedItems.querySelector('[data-collapsed-item]') ?? expandAction).focus();
    } else if (nextTrigger) {
      nextTrigger.focus();
    } else {
      emptyState.focus();
    }
  });

  emptyState.addEventListener('click', () => {
    const configPanel = document.getElementById('sample-pinchos-config');
    const disclosure = configPanel?.closest('details');
    if (disclosure) disclosure.open = true;
  });

  const errorCopy = panel.querySelector('[data-copy-error]');
  errorCopy?.addEventListener('click', () => {
    const errorText = errorCopy.dataset.errorText ?? '';
    const copyResult = navigator.clipboard?.writeText(errorText);
    if (!copyResult) {
      feedback.hidden = false;
      feedback.textContent = 'Copy unavailable in this browser';
      return;
    }

    copyResult.then(() => {
      feedback.hidden = false;
      feedback.textContent = 'Full error copied';
    }).catch(() => {
      feedback.hidden = false;
      feedback.textContent = 'Copy unavailable in this browser';
    });
  });

  document.addEventListener('click', (event) => {
    if ((panelOpen || collapsedRootOpen) && !root.contains(event.target)) {
      panelOpen = false;
      collapsedRootOpen = false;
      diagnosticsVisible = false;
      diagnostics.open = false;
      updatePanel();
    }
  });

  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || !root.contains(document.activeElement)) return;
    if (collapsed && panelOpen) {
      event.preventDefault();
      closePanel();
      collapsedItems.querySelector(`[data-collapsed-item="${activeName}"]`)?.focus();
    } else if (collapsedRootOpen) {
      event.preventDefault();
      closeCollapsedRoot();
    } else if (panelOpen) {
      event.preventDefault();
      closePanel();
      activeTrigger()?.focus();
    }
  });

  window.addEventListener('pagehide', () => {
    timers.forEach((timer) => window.clearTimeout(timer));
  }, { once: true });

  updatePanel();
};

const start = () => {
  document.querySelectorAll('[data-interactive-menu]').forEach(initializeMenu);
};

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', start, { once: true });
} else {
  start();
}
