import { defineCollection, reference } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const blog = defineCollection({
	loader: glob({ base: './src/content/blog', pattern: '**/*.{md,mdx}' }),
	schema: ({ image }) =>
		z.object({
			title: z.string(),
			subtitle: z.string(),
			description: z.string().optional(),
			pubDate: z.coerce.date(),
			updatedDate: z.date().optional(),
			draft: z.boolean().default(false),
			views: z.number().default(0),
			category: z.enum(['tech', 'life']).default('tech'),
			tags: z.array(z.string()).default([]),
			heroImage: image().optional(),
			author: reference('authors'),
			extra: z.custom((value) => typeof value === 'string'),
		}),
});

export const collections = { blog };
