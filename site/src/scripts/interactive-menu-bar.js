const initializeMenu = (root) => {
  const panel = root.querySelector('[data-example-panel]');
  const triggers = [...root.querySelectorAll('[data-menu-item]')];
  const refreshAction = panel?.querySelector('[data-refresh-action]');
  const clickLink = panel?.querySelector('[data-click-link]');
  const noClick = panel?.querySelector('[data-no-click]');
  const summary = panel?.querySelector('[data-summary]');
  const failureDetails = panel?.querySelector('[data-failure-details]');
  const meta = panel?.querySelector('[data-item-meta]');
  const diagnostics = panel?.querySelector('[data-diagnostics]');
  const diagnosticItem = panel?.querySelector('[data-diagnostic-item]');
  const diagnosticRefresh = panel?.querySelector('[data-diagnostic-refresh]');
  const diagnosticFormat = panel?.querySelector('[data-diagnostic-format]');
  const diagnosticClick = panel?.querySelector('[data-diagnostic-click]');
  const diagnosticError = panel?.querySelector('[data-diagnostic-error]');
  const diagnosticStale = panel?.querySelector('[data-diagnostic-stale]');
  const feedback = panel?.querySelector('[data-feedback]');

  if (!panel || !refreshAction || !clickLink || !noClick || !summary || !failureDetails || !meta || !diagnostics || !diagnosticItem || !diagnosticRefresh || !diagnosticFormat || !diagnosticClick || !diagnosticError || !diagnosticStale || !feedback || triggers.length === 0) {
    return;
  }

  const states = new Map(
    triggers.map((trigger) => [trigger.dataset.menuItem, {
      failed: trigger.dataset.initialState === 'failed',
      refreshing: false,
    }]),
  );
  const timers = new Map();
  let activeName = triggers[0].dataset.menuItem;
  let panelOpen = true;

  const stateFor = (name) => states.get(name) ?? { failed: false, refreshing: false };
  const activeTrigger = () => triggers.find((trigger) => trigger.dataset.menuItem === activeName);

  const updatePanel = () => {
    const trigger = activeTrigger();
    if (!trigger) return;

    const state = stateFor(activeName);
    const label = trigger.dataset.itemLabel ?? activeName;
    const value = trigger.dataset.value ?? '';
    const displayValue = state.failed ? trigger.dataset.displayValue : value;
    const interval = trigger.dataset.interval ?? '';
    const format = trigger.dataset.format || 'raw output';
    const clickCommand = trigger.dataset.clickCommand ?? '';
    const errorPolicy = trigger.dataset.errorPolicy || 'default';
    const staleAfter = trigger.dataset.staleAfter || 'not configured';
    const stateText = state.refreshing
      ? 'refreshing…'
      : state.failed
        ? 'failed · showing last good value'
        : 'updated just now';

    panel.hidden = !panelOpen;
    panel.dataset.state = state.refreshing ? 'running' : state.failed ? 'failed' : 'fresh';
    panel.setAttribute('aria-labelledby', trigger.id);
    panel.setAttribute('aria-label', `${label} item menu`);
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
    failureDetails.hidden = !state.failed;
    refreshAction.disabled = state.refreshing;
    refreshAction.textContent = state.refreshing ? 'Refreshing…' : 'Refresh Now';
    clickLink.hidden = !clickCommand;
    noClick.hidden = Boolean(clickCommand);

    if (clickCommand) {
      clickLink.href = trigger.dataset.clickUrl ?? '';
      clickLink.textContent = `Open ${label} usage page ↗`;
    } else {
      clickLink.removeAttribute('href');
    }

    triggers.forEach((itemTrigger) => {
      const isActive = itemTrigger === trigger;
      const itemState = stateFor(itemTrigger.dataset.menuItem);
      itemTrigger.setAttribute('aria-expanded', String(panelOpen && isActive));
      itemTrigger.dataset.state = itemState.refreshing ? 'running' : itemState.failed ? 'failed' : 'fresh';
      const itemDisplay = itemTrigger.querySelector('[data-item-display]');
      if (itemDisplay) itemDisplay.textContent = itemState.failed ? itemTrigger.dataset.displayValue : itemTrigger.dataset.value;
    });

    const spokenValue = value.replace('🔋 ', '').replace('%', ' percent');
    trigger.setAttribute('aria-label', `${label}, ${spokenValue}${state.failed ? ', failed, showing last good value' : ', fresh'}`);
  };

  const focusFirstAction = () => {
    const firstAction = panel.querySelector('[data-click-link]:not([hidden])') ?? refreshAction;
    firstAction.focus();
  };

  triggers.forEach((trigger) => {
    trigger.addEventListener('click', (event) => {
      const nextName = trigger.dataset.menuItem;
      if (nextName === activeName) {
        panelOpen = !panelOpen;
      } else {
        activeName = nextName;
        panelOpen = true;
        diagnostics.open = false;
      }
      updatePanel();
      if (panelOpen && event.detail === 0) focusFirstAction();
    });
  });

  refreshAction.addEventListener('click', () => {
    const itemName = activeName;
    const state = stateFor(itemName);
    if (state.refreshing) return;

    state.refreshing = true;
    updatePanel();
    const timer = window.setTimeout(() => {
      state.refreshing = false;
      state.failed = false;
      timers.delete(itemName);
      updatePanel();
    }, 450);
    timers.set(itemName, timer);
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

  document.addEventListener('pointerdown', (event) => {
    if (panelOpen && !root.contains(event.target)) {
      panelOpen = false;
      updatePanel();
    }
  }, { capture: true });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && panelOpen && root.contains(document.activeElement)) {
      event.preventDefault();
      panelOpen = false;
      updatePanel();
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
