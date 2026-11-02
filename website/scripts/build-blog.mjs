// Buildless production: commit generated HTML/Markdown alongside these sources.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { posts } from './blog-posts.mjs';
const root = fileURLToPath(new URL('..', import.meta.url));
const origin = 'https://getheymate.vercel.app';
const date = '2026-11-01';
const bySlug = new Map(posts.map(post => [post.slug, post]));
const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
function inline(text) {
  return escape(text).replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
    if (!/^(https:\/\/|\/(?!\/))/.test(href)) throw new Error(`Unsupported link: ${href}`);
    return `<a href="${href}">${label}</a>`;
  });
}
const sectionId = title => title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
function renderBlock(block) {
  switch (block.type) {
    case 'paragraph': return `<p>${inline(block.text)}</p>`;
    case 'prompt': return `<figure class="blog-prompt"><figcaption>Try this prompt</figcaption><blockquote><p>${escape(block.text)}</p></blockquote></figure>`;
    case 'list': case 'steps': {
      const tag = block.type === 'steps' ? 'ol' : 'ul';
      return `<${tag}>${block.items.map(item => `<li>${inline(item)}</li>`).join('')}</${tag}>`;
    }
    case 'table': return `<div class="document-table blog-table" role="region" aria-label="Comparison table" tabindex="0"><table><thead><tr>${block.headers.map(text => `<th scope="col">${escape(text)}</th>`).join('')}</tr></thead><tbody>${block.rows.map(row => `<tr>${row.map((text, i) => i === 0 ? `<th scope="row">${inline(text)}</th>` : `<td>${inline(text)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
    case 'image': return `<figure class="guide-figure"><img src="${escape(block.src)}" alt="${escape(block.alt)}" width="${block.width}" height="${block.height}" loading="lazy" decoding="async"><figcaption>${escape(block.caption)}</figcaption></figure>`;
    default: throw new Error(`Unknown content block: ${block.type}`);
  }
}
function markdownBlock(block) {
  switch (block.type) {
    case 'paragraph': return block.text;
    case 'prompt': return `Try this prompt:\n\n> ${block.text}`;
    case 'list': case 'steps': return block.items.map((text, i) => `${block.type === 'steps' ? i + 1 + '.' : '-'} ${text}`).join('\n');
    case 'table': return [block.headers, block.headers.map(() => '---'), ...block.rows].map(row => `| ${row.join(' | ')} |`).join('\n');
    case 'image': return `![${block.alt}](${origin}${block.src})\n\n${block.caption}`;
    default: throw new Error(`Unknown content block: ${block.type}`);
  }
}
function absoluteLinks(markdown) {
  return markdown.replace(/\]\((\/(?!\/)[^)]*)\)/g, `](${origin}$1)`);
}
const author = { '@type': 'Organization', name: 'HeyMate project', url: origin + '/' };
function layout({title, description, canonical, markdown, schema, content, article = false, image = '/assets/img/icon/icon-mischief-1024.png', imageAlt = 'HeyMate’s blue face app icon'}) {
 return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escape(title)} — HeyMate</title>
  <meta name="description" content="${escape(description)}">
  <meta name="author" content="HeyMate project">
  <meta name="robots" content="index, follow, max-image-preview:large">
  <link rel="canonical" href="${origin}${canonical}">
  <link rel="describedby" href="/llms.txt">
  <link rel="alternate" type="text/markdown" href="${markdown}" title="Markdown version">
  <link rel="alternate" type="application/rss+xml" href="/blog/feed.xml" title="HeyMate blog">
  <meta property="og:site_name" content="HeyMate">
  <meta property="og:type" content="${article ? 'article' : 'website'}">
  <meta property="og:title" content="${escape(title)}">
  <meta property="og:description" content="${escape(description)}">
  <meta property="og:url" content="${origin}${canonical}">
  <meta property="og:image" content="${origin}${escape(image)}">
  <meta property="og:image:alt" content="${escape(imageAlt)}">
  ${article ? `<meta property="article:published_time" content="${date}T00:00:00+08:00"><meta property="article:modified_time" content="${date}T00:00:00+08:00">` : ''}
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${escape(title)}">
  <meta name="twitter:description" content="${escape(description)}">
  <meta name="twitter:image" content="${origin}${escape(image)}">
  <meta name="theme-color" content="#f7f8fa">
  <link rel="icon" href="/assets/img/icon/favicon-mischief-32.png?v=blue-1" type="image/png">
  <link rel="preload" as="font" type="font/woff2" href="/assets/fonts/figtree-1.woff2" crossorigin>
  <link rel="stylesheet" href="/css/fonts.css?v=1">
  <link rel="stylesheet" href="/css/site.css?v=14">
  <link rel="stylesheet" href="/css/home.css?v=40">
  <link rel="stylesheet" href="/css/documents.css?v=2">
  <link rel="stylesheet" href="/css/blog.css?v=1">
  <script type="application/ld+json">${JSON.stringify(schema).replaceAll('<', '\\u003c')}</script>
</head>
<body class="home document-page blog-page">
  <a class="skip" href="#main">Skip to content</a>
  <header class="home-nav document-nav"><a class="brand" href="/"><img src="/assets/img/icon/apple-touch-mischief.png?v=blue-1" alt="" width="24" height="24">HeyMate</a><nav aria-label="Primary"><a href="/#possibilities">What it does</a><a class="nav-download" href="https://github.com/UmarSiddiqui/heymate/releases/latest/download/HeyMate.dmg">Get HeyMate <span aria-hidden="true">↓</span></a></nav></header>
  <nav class="document-links" aria-label="Resources"><a href="/blog"${!article ? ' aria-current="page"' : ''}>Blog &amp; guides</a><a href="/connect-claude-codex">Connect your AI</a><a href="/screen-guidance">Screen guidance</a><a href="/permissions">Permissions</a><a href="/privacy">Privacy</a></nav>
  ${content}
  <footer class="home-footer content-width"><a class="brand" href="/">HeyMate</a><nav aria-label="Footer"><a href="/blog">Blog &amp; guides</a><a href="/how-to-use-heymate">Get started</a><a href="/changelog">Changelog</a><a href="/privacy">Privacy</a><a href="/permissions">Permissions</a><a href="https://github.com/UmarSiddiqui/heymate">Source ↗</a></nav><p>© 2026 HeyMate</p></footer>
</body>
</html>
`;
}
await fs.mkdir(path.join(root, 'blog'), { recursive: true });
for (const post of posts) {
  if (!/^[a-z0-9-]+$/.test(post.slug)) throw new Error(`Invalid slug: ${post.slug}`);
  if (bySlug.size !== posts.length) throw new Error('Duplicate article slug');
  const canonical = '/blog/' + post.slug;
  const words = [post.answer, ...post.sections.flatMap(s => [s.title, ...s.blocks.map(b => b.text || (b.items || b.rows || []).flat().join(' '))])].join(' ').split(/\s+/).length;
  if (words < 400) throw new Error(`Article too thin: ${post.slug}, ${words} words`);
  const related = post.related.map(slug => {
    const item = bySlug.get(slug);
    if (!item || slug === post.slug) throw new Error(`Invalid related article: ${slug}`);
    return item;
  });
  const schema = { '@context': 'https://schema.org', '@graph': [
    { '@type': 'BlogPosting', '@id': origin + canonical + '#article', headline: post.title, description: post.description, datePublished: date + 'T00:00:00+08:00', dateModified: date + 'T00:00:00+08:00', author, publisher: author, url: origin + canonical, mainEntityOfPage: origin + canonical, image: origin + (post.image || '/assets/img/icon/icon-mischief-1024.png'), inLanguage: 'en', articleSection: post.category, wordCount: words, isPartOf: { '@id': origin + '/blog#blog' } },
    { '@type': 'BreadcrumbList', itemListElement: [{ '@type': 'ListItem', position: 1, name: 'HeyMate', item: origin + '/' }, { '@type': 'ListItem', position: 2, name: 'Blog & guides', item: origin + '/blog' }, { '@type': 'ListItem', position: 3, name: post.title, item: origin + canonical }] }
  ] };
  if (post.video) {
    const videoId = origin + canonical + '#film';
    schema['@graph'][0].video = { '@id': videoId };
    schema['@graph'].push({ '@type': 'VideoObject', '@id': videoId, name: post.video.label, description: post.description, thumbnailUrl: [origin + post.video.poster], uploadDate: date + 'T00:00:00+08:00', duration: post.video.duration, contentUrl: origin + post.video.src, inLanguage: 'en', transcript: post.video.transcript.map(([time, text]) => time + ' ' + text).join('\n') });
  }
  const media = post.video ? `<figure class="launch-film" id="film"><div class="launch-film-stage"><video controls playsinline preload="none" width="1920" height="1080" poster="${escape(post.video.poster)}" aria-label="${escape(post.video.label)}"><source src="${escape(post.video.src)}" type="video/mp4"><track kind="captions" src="${escape(post.video.captions)}" srclang="en" label="English (on-screen text)"><p><a href="${escape(post.video.src)}">Download the 60-second HeyMate film</a>.</p></video></div><figcaption><span>60 seconds · Original soundtrack · Recorded and illustrated scenes</span><a href="${escape(post.video.src)}" download>Download film ↗</a></figcaption><details class="launch-transcript"><summary>Read the film transcript</summary><ol>${post.video.transcript.map(([time, text]) => `<li><span>${escape(time)}</span><p>${escape(text)}</p></li>`).join('')}</ol></details></figure>` : '';
  const toc = post.sections.map(s => `<a href="#${sectionId(s.title)}">${escape(s.title)}</a>`).join('');
  const sections = post.sections.map(s => `<h2 id="${sectionId(s.title)}">${escape(s.title)}</h2>\n${s.blocks.map(renderBlock).join('\n')}`).join('\n');
  const content = `<main class="document-main content-width${post.video ? ' launch-story' : ''}" id="main">
    <header class="document-hero"><p class="eyebrow">${escape(post.topic)} · ${post.video ? '60-second film' : Math.ceil(words / 220) + ' min read'}</p><h1>${escape(post.heroTitle || post.title).replaceAll('\n', '<br>')}</h1><p>${escape(post.description)}</p><p class="blog-byline">By the HeyMate project · <time datetime="${date}">November 1, 2026</time>${post.category === 'Comparisons' ? ' · Documentation comparison' : ''}</p></header>
    ${media}
    <div class="document-layout"><aside class="document-contents"><nav aria-label="On this page"><p>On this page</p>${toc}<a href="#related-reading">Related reading</a></nav></aside><article class="document-body">
    <aside class="blog-answer" aria-label="At a glance"><p>${escape(post.answer)}</p></aside>
    ${sections}
    <h2 id="related-reading">Related reading</h2><ul>${related.map(item => `<li><a href="/blog/${item.slug}">${escape(item.title)}</a></li>`).join('')}</ul>
    <div class="blog-next"><h2>Try it with one small task.</h2><p>HeyMate is free and open source for macOS 14.2 and later. Bring your own AI; provider limits and optional service fees apply. Current builds are self-signed and not Apple notarized.</p><p><a class="download-button" href="/connect-claude-codex">Set up HeyMate on Mac <span aria-hidden="true">↗</span></a></p></div>
    </article></div>
  </main>`;
  await fs.writeFile(path.join(root, 'blog', post.slug + '.html'), layout({title: post.title, description: post.description, canonical, markdown: canonical + '.md', schema, content, article: true, image: post.image, imageAlt: post.imageAlt}));
  const mediaMarkdown = post.video ? `\n\n[Watch the 60-second film](${origin}${post.video.src})\n\n## Film transcript\n\n${post.video.transcript.map(([time,text]) => `- **${time}** ${text}`).join('\n')}` : '';
  const md = `# ${post.title}\n\n${post.description}${mediaMarkdown}\n\nBy the HeyMate project. Published ${date}. Category: ${post.category}.\n\n> ${post.answer}\n\n` + post.sections.map(s => `## ${s.title}\n\n${s.blocks.map(markdownBlock).join('\n\n')}`).join('\n\n') + '\n\n## Related reading\n\n' + related.map(p => `- [${p.title}](/blog/${p.slug})`).join('\n') + '\n\n[Set up HeyMate](/connect-claude-codex) · [Privacy](/privacy) · [Permissions](/permissions)\n';
  await fs.writeFile(path.join(root, 'blog', post.slug + '.md'), absoluteLinks(md));
}
const groups = [
 { name: 'Launch', id: 'launch', intro: 'New from HeyMate. Meet the product and the ideas behind it.' },
 { name: 'Workflows', id: 'workflows', intro: 'Start with something you already do. Keep the task small, the instructions clear, and the result easy to check.' },
 { name: 'Comparisons', id: 'comparisons', intro: 'Different tools suit different habits. Compare the choices that affect your work, with official sources and reasons to choose either.' },
 { name: 'Choosing tools', id: 'choosing-tools', intro: 'Understand the tradeoffs before giving an assistant access to your Mac.' }
];
const hubTitle = 'Mac AI workflows, comparisons, and practical guides';
const hubDescription = 'Explore HeyMate use cases for learning, design, coding, research, and everyday work. Compare Raycast, Alfred, Claude Cowork, and Apple Shortcuts.';
const hubSchema = { '@context': 'https://schema.org', '@type': 'Blog', '@id': origin + '/blog#blog', name: 'HeyMate Blog & Guides', description: hubDescription, url: origin + '/blog', publisher: author, blogPost: posts.map(p => ({ '@type': 'BlogPosting', headline: p.title, url: origin + '/blog/' + p.slug, datePublished: date + 'T00:00:00+08:00', author })) };
const groupMarkup = groups.filter(group => group.name !== 'Launch').map(group => `<section class="blog-group" id="${group.id}" aria-labelledby="${group.id}-title"><header><h2 id="${group.id}-title">${group.name}</h2><p>${group.intro}</p></header><div class="blog-grid">${posts.filter(p => p.category === group.name).map(p => `<article class="blog-entry"><p class="blog-topic">${escape(p.topic)}</p><h3><a href="/blog/${p.slug}">${escape(p.title)}</a></h3><p>${escape(p.description)}</p><a class="blog-read" href="/blog/${p.slug}">Read ${p.category === 'Comparisons' ? 'comparison' : 'guide'} <span class="sr-only">: ${escape(p.title)}</span><span aria-hidden="true"> ↗</span></a></article>`).join('')}</div></section>`).join('\n');
const launch = posts.find(post => post.category === 'Launch' && post.video);
const featured = launch ? `<section class="launch-feature" id="launch" aria-labelledby="launch-title"><a class="launch-feature-media" href="/blog/${launch.slug}" aria-label="Read ${escape(launch.title)}"><img src="${escape(launch.video.poster)}" width="1280" height="720" alt="${escape(launch.imageAlt)}" loading="lazy" decoding="async"><span>Watch the 60-second film <span aria-hidden="true">↗</span></span></a><div><p class="blog-topic">New from HeyMate · November 1, 2026</p><h2 id="launch-title"><a href="/blog/${launch.slug}">${escape(launch.title)}</a></h2><p>${escape(launch.description)}</p><a class="blog-read" href="/blog/${launch.slug}">Meet HeyMate <span aria-hidden="true">↗</span></a></div></section>` : '';
const hubContent = `<main class="document-main content-width" id="main"><header class="document-hero blog-hub-hero"><p class="eyebrow">The HeyMate field guide</p><h1>Practical AI workflows for your Mac.</h1><p>Learn a tool. Untangle an error. Give a mate a job. Useful ways to work with AI, with the prompts, tradeoffs, and checks that make the difference.</p><nav class="blog-jump" aria-label="Browse article categories">${groups.map(g => `<a href="#${g.id}">${g.name}</a>`).join('')}<a href="/connect-claude-codex">Start here: connect your AI ↗</a></nav></header>${featured}<div class="blog-index">${groupMarkup}</div><aside class="blog-editorial"><h2>Written from the HeyMate side of the desk.</h2><p>These guides are published by the HeyMate project. Workflow prompts are examples, not performance guarantees. Comparisons use linked official documentation checked November 1, 2026; they are not hands-on benchmarks or independent reviews.</p><p><a href="https://github.com/UmarSiddiqui/heymate/issues">Report an outdated detail</a> · <a href="/blog/feed.xml">Subscribe with RSS</a> · <a href="/privacy">Understand privacy</a></p></aside></main>`;
await fs.writeFile(path.join(root, 'blog', 'index.html'), layout({title: hubTitle, description: hubDescription, canonical: '/blog', markdown: '/blog/index.md', schema: hubSchema, content: hubContent}));
await fs.writeFile(path.join(root, 'blog', 'index.md'), `# HeyMate blog and guides\n\n${hubDescription}\n\nPublished by the HeyMate project. Comparison sources checked ${date}; no hands-on benchmark is claimed.\n\n` + groups.map(g => `## ${g.name}\n\n${posts.filter(p => p.category === g.name).map(p => `- [${p.title}](${origin}/blog/${p.slug}.md): ${p.description}`).join('\n')}`).join('\n\n') + '\n');
const feed = `<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>HeyMate Blog &amp; Guides</title><link>${origin}/blog</link><description>${escape(hubDescription)}</description><language>en</language><atom:link href="${origin}/blog/feed.xml" rel="self" type="application/rss+xml"/>${posts.map(p => `<item><title>${escape(p.title)}</title><link>${origin}/blog/${p.slug}</link><guid isPermaLink="true">${origin}/blog/${p.slug}</guid><description>${escape(p.description)}</description><pubDate>Sun, 01 Nov 2026 00:00:00 +0800</pubDate></item>`).join('')}</channel></rss>\n`;
await fs.writeFile(path.join(root, 'blog', 'feed.xml'), feed);
const sitemapPath = path.join(root, 'sitemap.xml');
let sitemap = await fs.readFile(sitemapPath, 'utf8');
sitemap = sitemap.replace(/\s*<!-- blog:start -->[\s\S]*?<!-- blog:end -->/g, '');
const urls = ['/blog', ...posts.map(p => '/blog/' + p.slug)];
sitemap = sitemap.replace('</urlset>', `  <!-- blog:start -->\n${urls.map(url => `  <url><loc>${origin}${url}</loc><lastmod>${date}</lastmod></url>`).join('\n')}\n  <!-- blog:end -->\n</urlset>`);
await fs.writeFile(sitemapPath, sitemap);
const llmsPath = path.join(root, 'llms.txt');
let llms = await fs.readFile(llmsPath, 'utf8');
llms = llms.replace(/\n<!-- blog:start -->[\s\S]*?<!-- blog:end -->\n/g, '\n');
const llmsBlog = `\n<!-- blog:start -->\n## Use cases and comparisons\n\n- [All guides](${origin}/blog/index.md): Browse practical workflows and project-published comparisons.\n${posts.map(p => `- [${p.title}](${origin}/blog/${p.slug}.md): ${p.topic}.`).join('\n')}\n<!-- blog:end -->\n`;
llms = llms.replace('## Optional', llmsBlog + '\n## Optional').replace(/\n{3,}/g, '\n\n');
await fs.writeFile(llmsPath, llms);
console.log(`Built ${posts.length} articles, Markdown copies, blog hub, RSS, sitemap entries, and LLM links.`);
