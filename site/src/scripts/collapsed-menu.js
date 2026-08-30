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
  const render = () => {
    collapsedItems.replaceChildren();
    const visible = visibleTriggers();
    collapsedEmpty.hidden = visible.length !== 0;

    visible.forEach((trigger) => {
      const itemName = trigger.dataset.menuItem;
      const itemState = stateFor(itemName);
      const label = trigger.dataset.itemLabel ?? itemName;
      const value = itemState.failed ? trigger.dataset.displayValue : trigger.dataset.value;
      const row = document.createElement('button');
      row.className = 'collapsed-menu__item';
      row.type = 'button';
      row.setAttribute('role', 'menuitem');
      row.setAttribute('aria-haspopup', 'menu');
      row.setAttribute('aria-controls', 'example-menu-panel');
      row.setAttribute('aria-expanded', String(isRootOpen() && isPanelOpen() && activeName() === itemName));
      row.dataset.collapsedItem = itemName;
      row.dataset.state = itemState.refreshing ? 'running' : itemState.failed ? 'failed' : 'fresh';

      const name = document.createElement('span');
      name.className = 'collapsed-menu__item-name';
      name.textContent = label;
      row.append(name);

      if (value) {
        const preview = document.createElement('span');
        preview.className = 'collapsed-menu__item-value';
        preview.textContent = value;
        row.append(preview);
      }

      const indicator = document.createElement('span');
      indicator.className = 'collapsed-menu__item-indicator';
      indicator.setAttribute('aria-hidden', 'true');
      indicator.textContent = '›';
      row.append(indicator);

      row.setAttribute('aria-label', `${label}${value ? `, ${value}` : ''}`);
      row.addEventListener('pointerenter', () => openCollapsedItem(trigger, false));
      row.addEventListener('click', (event) => {
        event.stopPropagation();
        openCollapsedItem(trigger, event.detail === 0);
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
          openCollapsedItem(trigger, true);
        } else if (event.key === 'Escape') {
          event.preventDefault();
          closeRoot();
        }
      });
      collapsedItems.append(row);
    });
  };

  const openCollapsedItem = (trigger, focusActions) => {
    if (!isCollapsed() || !isRootOpen()) return;
    openItem(trigger);
    if (focusActions) focusFirstAction();
  };

  return { render };
};
