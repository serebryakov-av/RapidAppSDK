//
//  RAFileCache.m
//  TNK-BP
//
//  Created by Anton Serebryakov on 29.11.12.
//  Copyright (c) 2012 iDEAST. All rights reserved.
//

#import "RAFileCache.h"
#import "RAHelper.h"


// Для отладки
#define RAFC_SHORTYFY(URL) RA_SHORTYFY(URL.absoluteString, 35)

// Имя идректории с файлами кэша
#define RA_CACHE_DIR @"RapidAppSDK.FileCache.V1"


@implementation RAFileCache

+ (NSString *)cachesDirectoryPath
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
	return basePath;
}

+ (NSString *)fileCachePath
{
	static NSString *fileCachePath = nil;
	if (!fileCachePath)
	{
		fileCachePath = [[self cachesDirectoryPath] stringByAppendingPathComponent:RA_CACHE_DIR];
		[fileCachePath retain];
	}
	return fileCachePath;
}

+ (void)checkCacheDirectoryAndCreate
{
	NSString *cacheDirectoryPath = [self fileCachePath];
	BOOL isDirectory = NO;
	BOOL isExists = [[NSFileManager defaultManager] fileExistsAtPath:cacheDirectoryPath isDirectory:&isDirectory];
	if (!isExists || !isDirectory)
	{
		NSLog(@"[RAFileCache] Инициализация файлового кэша (файловая система)");
		if (isExists)
			[[NSFileManager defaultManager] removeItemAtPath:cacheDirectoryPath error:nil];
		[[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
	}
}

+ (void)initialize
{
	[self checkCacheDirectoryAndCreate];
}

/*
 Генерирует имя файла в кеше по его URL.
 */
+ (NSURL *)cacheURLForURL:(NSURL *)url
{
	if (!url)
		return nil;
	
	NSString *urlString = url.absoluteString;
	NSString *md5 = [RAHelper md5FromString:urlString];
	NSString *name = [md5 stringByAppendingPathExtension:[urlString pathExtension]];
	NSString *path = [[self fileCachePath] stringByAppendingPathComponent:name];
	return [NSURL fileURLWithPath:path];
}

+ (BOOL)setCache:(NSData *)value withDate:(NSDate *)date forURL:(NSURL *)url
{
	if (value && url)
	{
		NSURL *cacheURL = [self cacheURLForURL:url];
		if (!date)
			date = [NSDate dateWithTimeIntervalSince1970:0];
		NSDictionary *attributes = @{ NSFileModificationDate:date };
		
		if ([[NSFileManager defaultManager] createFileAtPath:cacheURL.path contents:value attributes:attributes])
		{
			NSLog(@"[RAFileCache] Cached! [%@] -> [%@]", RAFC_SHORTYFY(url), RAFC_SHORTYFY(cacheURL));
			return YES;
		}
	}
	NSLog(@"[RAFileCache] Error!! [%@]", RAFC_SHORTYFY(url));
	return NO;
}

+ (BOOL)isURLCached:(NSURL *)url
{
	if (url)
	{
		NSURL *cacheURL = [self cacheURLForURL:url];
		BOOL result = [[NSFileManager defaultManager] fileExistsAtPath:cacheURL.path];
		NSLog(@"[RAFileCache] %s [%@] -> [%@]", (result ? "Exists!" : "Empty.."), RAFC_SHORTYFY(url), RAFC_SHORTYFY(cacheURL));
		return result;
	}
	// ВАЖНО! Нужно возвращать YES, чтобы не было ошибок с URL === nil
	NSLog(@"[RAFileCache] Exists! [%@]", RAFC_SHORTYFY(url));
	return YES;
}

+ (void)removeCacheForURL:(NSURL *)url
{
	if (url)
	{
		NSURL *cacheURL = [self cacheURLForURL:url];
		[[NSFileManager defaultManager] removeItemAtURL:cacheURL error:nil];
		NSLog(@"[RAFileCache] ^_^ [%@] -> [%@]", RAFC_SHORTYFY(url), RAFC_SHORTYFY(cacheURL));
	}
}

+ (NSData *)cacheForURL:(NSURL *)url
{
	if (url)
	{
		NSURL *cacheURL = [self cacheURLForURL:url];
		// Содержимое файла
		NSData *value = [NSData dataWithContentsOfURL:cacheURL];
		NSLog(@"[RAFileCache] ^_^ [%@] -> [%@]", RAFC_SHORTYFY(url), RAFC_SHORTYFY(cacheURL));
		return value;
	}
	NSLog(@"[RAFileCache] :-( [%@]", RAFC_SHORTYFY(url));
	return nil;
}

+ (NSData *)cacheForURL:(NSURL *)url withDate:(NSDate **)date
{
	if (url)
	{
		NSURL *cacheURL = [self cacheURLForURL:url];
		// Время последней модификации
		NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:cacheURL.path error:nil];
		*date = [[[attributes fileModificationDate] retain] autorelease];
		// Содержимое файла
		NSData *value = [NSData dataWithContentsOfURL:cacheURL];
		NSLog(@"[RAFileCache] ^_^ [%@] -> [%@]", RAFC_SHORTYFY(url), RAFC_SHORTYFY(cacheURL));
		return value;
	}
	NSLog(@"[RAFileCache] :-( [%@]", RAFC_SHORTYFY(url));
	return nil;
}

+ (void)clear
{
	NSLog(@"[RAFileCache] Внимание! Очистка кэша!");
	[[NSFileManager defaultManager] removeItemAtPath:[self fileCachePath] error:nil];
	[self checkCacheDirectoryAndCreate];
}

@end