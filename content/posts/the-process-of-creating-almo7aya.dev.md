---
title: "The Process Of Creating almo7aya.dev"
date: 2022-10-05T06:42:43+03:00
draft: false
description: Why and how I created almo7aya.dev with more technical details
---

## Why

I have been thinking about creating a personal website for myself to show my projects and to write about the interesting stuff I found online, and maybe to write some blogs about my learnings and the other tools that I'm using on my daily basis.

## Static Site Generator

This is what took me so long to create personal website, I always wanted a to create a website for me, but every time I get stuck because I didn't feel the static generator is good enough.  

So in the last week I almost tried all the static generators out there eg: [Jekyll](https://jekyllrb.com/), [Hexo](https://hexo.io/), [Eleventy](https://github.com/11ty/eleventy), and many others, and I ended up using [Hugo](https://gohugo.io/) as a static site generator for my website, It's written in go, so it's light and fast, and very easy to get started with, the documentations is good and I didn't face any issue setting it up.

## Theming

This part is best part of the process, after I was sure about using [Hugo](https://gohugo.io/) I started searching for a theme from the [list on Hugo's website](https://themes.gohugo.io/), and found some beautiful themes, but most of them are not perfect for me, I wanted something very simple, and makes you feel like the you are inside terminal, I got inspired by [@sachaos](https://blog.sachaos.dev/)'s website, and decided to edit one of Hugo's themes, so I forked [hugo-theme-cactus](https://github.com/monkeyWzr/hugo-theme-cactus) and added my [changes](https://github.com/Almo7aya/hugo-theme-cactus) on top of it, I didn't think about someone using my fork so I didn't add any configurations for the things I added and removed some of its main layouts and finally I took the last inspiration for the header from [hugo-theme-terminal](https://github.com/panr/hugo-theme-terminal), and I changed some of the css properties to disable the ToC and the floating actions icons they didn't work right and they were not that responsive.

## Hosting, Deployment and using custom domain

I use [GitHub Actions](https://github.com/features/actions) to build the website, and [GitHub Pages](https://pages.github.com/) to host it, Hugo has a nice [Action](https://gohugo.io/hosting-and-deployment/hosting-on-github/) to automatically build and deploy the project on GitHub Pages when every there is a new commit in the main branch, here is my action workflow file [hugo-deploy-to-gh-page.yml](https://github.com/Almo7aya/almo7aya.github.io/blob/main/.github/workflows/hugo-deploy-to-gh-page.yml).

By default the website will be hosted on [almo7aya.github.io](almo7aya.github.io) and it needs some configurations to work on my domain [almo7aya.dev](almo7aya.dev), GitHub Pages requires the custom domain to have a CNAME DNS record pointing to the gh page's URL which is almo7aya.github.io in my case
![CNAME RECORD](/images/2022-10-05_08-03.png)
after that I added it to the repo pages settings as a custom domain
![GITHUB CUSTOM DOMAIN](/images/2022-10-05_08-09.png)
and now my website is live on almo7aya.dev.

As a side note Hugo's gh action will clean the gh-pages branch on every deploy and that causes gh pages to remove the custom domain,
To fix this I created a file called `/static/CNAME` and put inside my custom domain so it does not get removed by the action.

I'm satisfied with this workflow it's fast and fully automated, regardless of gh pages has a native support for Jekyll to auto build and deploy, Jekyll was a nightmare to run locally on my MacBook with M1 chip, since it's written in ruby and it's not compatible with the pre-installed ruby version on my Mac I had to run it inside a docker container to escape from the compatibility issues, and I was not convinced enough to keep developing it inside a container.

## Plugins

I only have one plugin which is [utteranc](https://utteranc.es/) to add comments to my posts, It uses github issues to store and manage the comments, setting it up was easy, just installed it on the website's repo and linked it in the Hugo config file.

## Conclusion

Creating this project was fun, I learned so much stuff about Static Site Generators, markdown, ruby, and github APIs.

