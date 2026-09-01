import { readdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export interface RecipeItem {
  readonly name: string;
  readonly run: string;
  readonly format: string;
  readonly interval: string;
  readonly preview: string;
  readonly menuRows: readonly string[];
}

export interface Recipe {
  readonly slug: string;
  readonly filename: string;
  readonly title: string;
  readonly category: string;
  readonly source: string;
  readonly items: readonly RecipeItem[];
  readonly searchText: string;
}

const recipesDirectory = resolve(process.cwd(), '../recipes');
const itemHeaderPattern = /^\[item\.([A-Za-z0-9_-]+)\]\s*$/gm;

const readStringField = (section: string, key: string): string => {
  const match = section.match(new RegExp(`^${key} = "((?:\\\\.|[^"])*)"$`, 'm'));
  return match?.[1]?.replace(/\\"/g, '"').replace(/\\\\/g, '\\') ?? '';
};

const readMenuRows = (section: string): readonly string[] => Array.from(
  section.matchAll(/^\[\[item\.[^\]]+\.menu\]\][\s\S]*?^label = "([^"]+)"/gm),
  (match) => match[1],
);

const readExpectedCommandOutput = (sourceBeforeHeader: string): string => {
  let raw = 'sample output';
  for (const match of sourceBeforeHeader.matchAll(/^# Expected output:\s*(.+)$/gm)) {
    if (match[1]) raw = match[1].trim();
  }

  return raw.match(/"([^"]+)"/)?.[1] ?? raw.replace(/\.$/, '');
};

const readItems = (source: string): readonly RecipeItem[] => {
  const headers = Array.from(source.matchAll(itemHeaderPattern));

  return headers.flatMap((header, index) => {
    const name = header[1];
    const start = header.index;
    if (!name || start === undefined) return [];

    const nextHeader = headers[index + 1];
    const end = nextHeader?.index ?? source.length;
    const section = source.slice(start, end);
    const format = readStringField(section, 'format') || '{output}';
    const interval = readStringField(section, 'interval') || 'on demand';
    const example = readExpectedCommandOutput(source.slice(0, start));

    return [{
      name,
      run: readStringField(section, 'run'),
      format,
      interval,
      preview: format.replace('{output}', example),
      menuRows: readMenuRows(section),
    }];
  });
};

const readRecipe = (filename: string): Recipe => {
  const source = readFileSync(resolve(recipesDirectory, filename), 'utf8');
  const slug = filename.replace(/\.toml$/, '');
  const recipeLabel = source.match(/^# Recipe:\s*(.+)$/m)?.[1]?.trim() ?? slug;
  const title = recipeLabel.replace(/\s+\([^)]*\)$/, '');
  const category = source.match(/^# Category:\s*(.+)$/m)?.[1]?.trim() ?? 'General';
  const items = readItems(source);

  return {
    slug,
    filename,
    title,
    category,
    source,
    items,
    searchText: [title, category, filename, ...items.map((item) => `${item.name} ${item.run} ${item.format} ${item.menuRows.join(' ')}`), source]
      .join(' ')
      .toLocaleLowerCase('en-US'),
  };
};

export const loadRecipes = (): readonly Recipe[] => readdirSync(recipesDirectory, { withFileTypes: true })
  .filter((entry) => entry.isFile() && entry.name.endsWith('.toml'))
  .map((entry) => entry.name)
  .sort((left, right) => left.localeCompare(right))
  .map(readRecipe);
