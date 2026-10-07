// RSS at /index.xml, the same URL Hugo used, so existing subscribers keep working
import rss from '@astrojs/rss';
import { getPosts } from '../lib/posts';

export function GET(context) {
  return rss({
    title: 'almo7aya.dev',
    description: 'Ali Almohaya: Staff Web Engineer at Anghami & OSN+, building web and smart-TV streaming apps, specialist in video playback and DRM. Beyond the web: low-level programming, emulation, C++ and graphics.',
    site: context.site,
    items: getPosts().map(p => ({ title: p.title, pubDate: p.date, description: p.description, link: `/posts/${p.slug}/` })),
  });
}
