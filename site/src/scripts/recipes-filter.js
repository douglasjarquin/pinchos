const root = document.querySelector('[data-recipe-explorer]');
const search = root?.querySelector('[data-recipe-search]');
const resultCount = root?.querySelector('[data-recipe-result-count]');
const emptyState = root?.querySelector('[data-recipe-empty]');
const cards = root ? [...root.querySelectorAll('[data-recipe-card]')] : [];

if (search instanceof HTMLInputElement && resultCount && emptyState) {
  const updateResults = () => {
    const query = search.value.trim().toLocaleLowerCase();
    let visibleCount = 0;

    cards.forEach((card) => {
      const searchableText = card.dataset.searchText ?? '';
      const matches = query === '' || searchableText.includes(query);
      card.hidden = !matches;
      if (matches) visibleCount += 1;
    });

    resultCount.textContent = `${visibleCount} ${visibleCount === 1 ? 'recipe' : 'recipes'}`;
    emptyState.hidden = visibleCount !== 0;
  };

  search.addEventListener('input', updateResults);
  search.addEventListener('search', updateResults);
  updateResults();
}
