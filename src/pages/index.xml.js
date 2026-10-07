// RSS at /index.xml, the same URL Hugo used, so existing subscribers keep working
import rss from '@astrojs/rss';
import { getPosts } from '../lib/posts';

export function GET(context) {
  return rss({
    title: 'almo7aya.dev',
    description: 'Ali Almohaya: staff web engineer at Anghami & OSN+. Video player, DRM and TV apps by day; emulators and C++ after hours.',
    site: context.site,
    items: getPosts().map(p => ({ title: p.title, pubDate: p.date, description: p.description, link: `/posts/${p.slug}/` })),
  });
}
