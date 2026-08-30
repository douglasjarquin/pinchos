export const createCollapsedMenuController = ({
  collapsedItems,
  collapsedEmpty,
  visibleTriggers,
  stateFor,
  isCollapsed,
  isRootOpen,
  isPanelOpen,
  activeName,
  expandAction,
  openItem,
  closeRoot,
  focusFirstAction,
}) => {
  const rowsByName = new Map();

  const createRow = (trigger) => {
    const itemName = trigger.dataset.menuItem;
    const row = document.createElement('button');
    row.className = 'collapsed-menu__item';
    row.type = 'button';
    row.setAttribute('role', 'menuitem');
    row.setAttribute('aria-haspopup', 'menu');
    row.setAttribute('aria-controls', 'example-menu-panel');
    row.dataset.collapsedItem = itemName;

    const name = document.createElement('span');
    name.className = 'collapsed-menu__item-name';
    row.append(name);

    const value = document.createElement('span');
    value.className = 'collapsed-menu__item-value';
    row.append(value);

    const indicator = document.createElement('span');
    indicator.className = 'collapsed-menu__item-indicator';
    indicator.setAttribute('aria-hidden', 'true');
    indicator.textContent = '›';
    row.append(indicator);

    row.addEventListener('pointerenter', () => {
      if (isPanelOpen() && activeName() === itemName) return;
      openCollapsedItem(trigger, false, false);
    });
    row.addEventListener('click', (event) => {
      event.stopPropagation();
      openCollapsedItem(trigger, event.altKey, event.detail === 0);
    });
    row.addEventListener('keydown', (event) => {
      const rows = [...collapsedItems.querySelectorAll('[data-collapsed-item]'), expandAction];
      const index = rows.indexOf(row);
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const delta = event.key === 'ArrowDown' ? 1 : -1;
        rows[(index + delta + rows.length) % rows.length]?.focus();
      } else if (event.key === 'ArrowRight' || event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        openCollapsedItem(trigger, false, true);
      } else if (event.key === 'Escape') {
        event.preventDefault();
        closeRoot();
      }
    });
    rowsByName.set(itemName, row);
    return row;
  };

  const render = () => {
    const visible = visibleTriggers();
    const visibleNames = new Set(visible.map((trigger) => trigger.dataset.menuItem));
    collapsedEmpty.hidden = visible.length !== 0;

    visible.forEach((trigger) => {
      const itemName = trigger.dataset.menuItem;
      const itemState = stateFor(itemName);
      const label = trigger.dataset.itemLabel ?? itemName;
      const value = itemState.failed ? trigger.dataset.displayValue : trigger.dataset.value;
      const row = rowsByName.get(itemName) ?? createRow(trigger);
      row.setAttribute('aria-controls', 'example-menu-panel');
      row.setAttribute('aria-expanded', String(isRootOpen() && isPanelOpen() && activeName() === itemName));
      row.dataset.state = itemState.refreshing ? 'running' : itemState.failed ? 'failed' : 'fresh';
      row.querySelector('.collapsed-menu__item-name').textContent = label;
      const valueElement = row.querySelector('.collapsed-menu__item-value');
      valueElement.hidden = !value;
      valueElement.textContent = value ?? '';
      row.setAttribute('aria-label', `${label}${value ? `, ${value}` : ''}`);
      collapsedItems.append(row);
    });

    rowsByName.forEach((row, itemName) => {
      if (!visibleNames.has(itemName)) row.remove();
    });
  };

  const openCollapsedItem = (trigger, showDiagnostics, focusActions) => {
    if (!isCollapsed() || !isRootOpen()) return;
    openItem(trigger, showDiagnostics);
    if (focusActions) focusFirstAction();
  };

  return { render };
};
