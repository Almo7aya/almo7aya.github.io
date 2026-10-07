// posts live in src/posts/*.md; `slug` in the frontmatter keeps the old Hugo URLs alive
export interface Post { slug: string; title: string; date: Date; description?: string; Content: any }

export function getPosts(): Post[] {
  const files = import.meta.glob('../posts/*.md', { eager: true }) as Record<string, any>;
  return Object.entries(files)
    .map(([path, mod]) => ({
      slug: mod.frontmatter.slug ?? path.split('/').pop()!.replace(/\.md$/, ''),
      title: mod.frontmatter.title,
      date: new Date(mod.frontmatter.date),
      description: mod.frontmatter.description,
      draft: mod.frontmatter.draft,
      Content: mod.Content,
    }))
    .filter(p => !p.draft)
    .sort((a, b) => b.date.getTime() - a.date.getTime());
}

export const fmtDate = (d: Date) => d.toISOString().slice(0, 10);
