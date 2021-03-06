//
//  RADataBase.m
//

#import "RADataBase.h"
#import <CoreData/CoreData.h>
#import "RASharedPrivate.h"


#define PROVIDE_TWEAK 0


NSString *RADataBaseIsReadyNotification = @"[RADataBase] Is ready notification";
NSString *RADataBaseIsReadyNotificationError = @"error";

static NSString *RADataBaseIsInitializedKey = @"[RADataBase] InitializedKeyFor [%@]";


@interface RADataBase ()
{
    NSMutableDictionary *fetchedPacks;
    NSMutableDictionary *updatedPacks;
}

@property (atomic, assign) BOOL isReady;
@property (atomic, retain) NSError *lastError;

@property (atomic, retain) NSManagedObjectModel *model;
@property (atomic, retain) NSManagedObjectContext *readContext;
@property (atomic, retain) NSManagedObjectContext *writeContext;

@end


@implementation RADataBase
SHARED_METHOD_IMPLEMENTATION


@synthesize databaseURL, databaseName;

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	self.modelURL = nil;
	[databaseURL release];
    [databaseName release];
	self.isReady = NO;
	self.readContext = nil;
	self.writeContext = nil;
	self.lastError = nil;
	[fetchedPacks release];
	[updatedPacks release];
	[super dealloc];
}

- (void)myInit
{
	if (!fetchedPacks)
		fetchedPacks = [NSMutableDictionary new];
	if (!updatedPacks)
		updatedPacks = [NSMutableDictionary new];
}

- (void)open
{
	[self myInit];
	[self close];
	[self recreateContexts];
}

- (void)reopen
{
	[self open];
}

- (void)close
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	self.isReady = NO;
	self.readContext = nil;
	self.writeContext = nil;
	self.model = nil;
	self.lastError = nil;
}

- (BOOL)save:(NSError **)error
{
	if ([self.writeContext hasChanges])
	{
		NSLog(@"%08x [RADataBase|%@] Changed: %i, Inserted: %i, Removed: %i", (int)self, NSStringFromSelector(_cmd), (int)[self.writeContext updatedObjects].count, (int)[self.writeContext insertedObjects].count, (int)[self.writeContext deletedObjects].count);
		NSError *anError = nil;
		if (![self.writeContext save:&anError])
		{
			if (anError)
			{
				NSLog(@"%08x [RADataBase|%@] [WARNING] %@", (int)self, NSStringFromSelector(_cmd), anError);
				self.lastError = anError;
				if (error && anError)
					*error = [[anError retain] autorelease];
			}
			return NO;
		}
	}
	return YES;
}

- (NSString *)dataBaseIsInitializedKey
{
    return [NSString stringWithFormat:RADataBaseIsInitializedKey, self.databaseURL.absoluteString];
}

- (void)clean
{
	[self close];
	
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:self.dataBaseIsInitializedKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	
	NSURL *storeURL = self.databaseURL;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if ([fileManager fileExistsAtPath:storeURL.path])
		[fileManager removeItemAtPath:storeURL.path error:nil];
}

- (NSURL *)databaseURL
{
	if (!databaseURL)
	{
		// Storage directory
		NSURL *cachesURL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
		// Path to local DB
		databaseURL = [[cachesURL URLByAppendingPathComponent:self.databaseName] retain];
	}
	return databaseURL;
}

- (NSString *)databaseName
{
    if (!databaseName)
        databaseName = [@"DataBase.sqlite" retain];
    return databaseName;
}

#pragma mark - Core Data Initializations

/*
 Данный метод делает следующее:
 1. Инициализация БД выполняется в фоне и гарантированно один раз в один промежуток времени.
 2. При некорректной инициализации посылается уведомление об этом с ошибкой (RADataBaseIsReadyNotification with error).
 3. При успешной инициализации уведомление так же имеется (RADataBaseIsReadyNotification).
 */
- (void)recreateContexts
{
	// Создаем семафор-мьютекс
	static dispatch_semaphore_t fd_sema = NULL;
	if (!fd_sema)
		fd_sema = dispatch_semaphore_create(1);
	
	NSLog(@"%08x [RADataBase|%@] Trying to create context", (int)self, NSStringFromSelector(_cmd));
	
	// Запускаем ожидаение мьютекса с таймаутом в 0 секунд
	if (fd_sema && (dispatch_semaphore_wait(fd_sema, DISPATCH_TIME_NOW) == 0))
	{
		self.isReady = NO;
		[[NSNotificationCenter defaultCenter] removeObserver:self];
		
		NSLog(@"%08x [RADataBase|%@] Now DB isn't ready...", (int)self, NSStringFromSelector(_cmd));
		
		// URL to database model
		NSURL *theModelURL = self.modelURL;
		// URL to storefile
		NSURL *storeURL = self.databaseURL;
		
		// Создаем контексты в фоновом потоке (отдельно от текущего)
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^ {
			// Deleting old files
			self.readContext = nil;
			self.writeContext = nil;
			
			// Здесь будет записана ошибка
			NSError *error = nil;
			
			// Оформляем как цикл, чтобы было легче прервать блок команд
			do {
				// Проверяем корректность пути к модели базы данных
				if (!theModelURL)
				{
					error = [NSError errorWithDomain:@"Can't load database model!" code:0 userInfo:nil];
					break;
				}
				
				// Initializing of model
				self.model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:theModelURL] autorelease];
				// Initializing of coordinator
				NSPersistentStoreCoordinator *coordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model] autorelease];
				
				// Опции оптимизации SQLite
#if PROVIDE_TWEAK
				NSDictionary *options = @{NSSQLitePragmasOption: @{@"synchronous": @"NORMAL", @"fullfsync": @"0"}};
#else
				NSDictionary *options = nil;
#endif
				
				// Пытаемся открыть базу данных
				while (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error])
				{
					// Если была ошибка и есть база данных, то удаляем ее и пытаемся создать ее с нуля
					NSFileManager *fileManager = [NSFileManager defaultManager];
					if ([fileManager fileExistsAtPath:storeURL.path])
					{
						NSLog(@"%08x [RADataBase|%@] [WARNING] Recreating DB! %@", (int)self, NSStringFromSelector(_cmd), error);
						if ([fileManager removeItemAtPath:storeURL.path error:nil])
						{
							// Стираем ошибку
							error = nil;
							// Отмечаем, что БД не проинициализирована!
							[[NSUserDefaults standardUserDefaults] removeObjectForKey:self.dataBaseIsInitializedKey];
							[[NSUserDefaults standardUserDefaults] synchronize];
						}
					}
					// Если непонятная ошибка, то сдаемся...
					else
					{
						break;
					}
				}
				
				if (error)
				{
					break;
				}
				
				// Key where stored flag, that defines wether DB initialized or not. Узнаем, проинициализирована ли БД.
				BOOL isInitialized = NO;
				if ([[NSUserDefaults standardUserDefaults] boolForKey:self.dataBaseIsInitializedKey])
					isInitialized = YES;
				
				// Если нужно, запускаем первичную инициализацию БД
				if (!isInitialized && [self.delegate respondsToSelector:@selector(primaryInitializationsForDataBase:withContext:)])
				{ @autoreleasepool {
					
					NSManagedObjectContext *context = [[NSManagedObjectContext new] autorelease];
					[context setPersistentStoreCoordinator:coordinator];
					[context setUndoManager:nil];
					[self.delegate primaryInitializationsForDataBase:self withContext:context];
					[context save:&error];
				}}
				
				if (error)
				{
					// Удаляем БД с файловой системы
					NSFileManager *fileManager = [NSFileManager defaultManager];
					[fileManager removeItemAtURL:storeURL error:nil];
					break;
				}
				
				// Отмечаем, что БД проинициализирована
				[[NSUserDefaults standardUserDefaults] setBool:YES forKey:self.dataBaseIsInitializedKey];
				[[NSUserDefaults standardUserDefaults] synchronize];
				
				// Контекст для записи
				NSManagedObjectContext *newWriteContext = [[NSManagedObjectContext new] autorelease];
				[newWriteContext setPersistentStoreCoordinator:coordinator];
#if PROVIDE_TWEAK
				[newWriteContext setUndoManager:nil];
#endif
				[newWriteContext setMergePolicy:NSOverwriteMergePolicy]; // Изменения в контексте главнее, чем в хранилище
				// Подписываемся на увемления об изменениях в контексте
				[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextForWriteDidSaved:) name:NSManagedObjectContextDidSaveNotification object:newWriteContext];
				
				// Контекст для чтения
				NSManagedObjectContext *newReadContext = [[NSManagedObjectContext new] autorelease];
				[newReadContext setPersistentStoreCoordinator:coordinator];
#if PROVIDE_TWEAK
				[newReadContext setUndoManager:nil];
#endif
				[newReadContext setMergePolicy:NSOverwriteMergePolicy]; // Данные хранилища главнее, чем в контексте
				
				// Сохраняем новые контексты
				self.readContext = newReadContext;
				self.writeContext = newWriteContext;
				
			} while (FALSE);
			
			if (!error)
			{
				NSLog(@"%08x [RADataBase|%@] Now DB is ready! ^_^", (int)self, NSStringFromSelector(_cmd));
				self.isReady = YES;
				self.lastError = nil;
				dispatch_sync(dispatch_get_main_queue(), ^ {
					[[NSNotificationCenter defaultCenter] postNotificationName:RADataBaseIsReadyNotification object:self];
				});
			}
			else
			{
				NSLog(@"%08x [RADataBase|%@] [CRITICAL] %@", (int)self, NSStringFromSelector(_cmd), error);
				self.lastError = error;
				dispatch_sync(dispatch_get_main_queue(), ^ {
					[[NSNotificationCenter defaultCenter] postNotificationName:RADataBaseIsReadyNotification object:self userInfo:@{RADataBaseIsReadyNotificationError:error}];
				});
			}
			
			// Освобождаем мьютекс
			dispatch_semaphore_signal(fd_sema);
		});
	}
}

- (void)contextForWriteDidSaved:(NSNotification *)note
{
	dispatch_async(dispatch_get_main_queue(), ^ {
		[self.readContext mergeChangesFromContextDidSaveNotification:note];
		[self.readContext save:nil];
	});
}

#pragma mark - Accessors

+ (NSManagedObject *)objectOfEntity:(NSString *)entity withParams:(NSDictionary *)params fromContext:(NSManagedObjectContext *)context
{
	__block NSMutableArray *array = [NSMutableArray array];
	[params enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
		NSPredicate *second = nil;
        if ([value isKindOfClass:[NSArray class]])
            second = [NSPredicate predicateWithFormat:@"%K IN %@", key, value];
        else
            second = [NSPredicate predicateWithFormat:@"%K == %@", key, value];
		[array addObject:second];
	}];
	NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:array];
	NSFetchRequest *request = [NSFetchRequest new];
	request.entity = [NSEntityDescription entityForName:entity inManagedObjectContext:context];
	request.predicate = predicate;
	request.fetchLimit = 1;
	NSArray *objects = [context executeFetchRequest:request error:nil];
	[request release];
	NSManagedObject *object = objects.lastObject;
	return object;
}

+ (NSArray *)objectsOfEntity:(NSString *)entity withParams:(NSDictionary *)params fromContext:(NSManagedObjectContext *)context
{
	return [RADataBase objectsOfEntity:entity withParams:params andNotSatisfyingParams:nil fromContext:context];
}

+ (id)objectsOfEntity:(NSString *)entity withParams:(NSDictionary *)params andNotSatisfyingParams:(NSDictionary *)notParams fromContext:(NSManagedObjectContext *)context
{
    __block NSMutableArray *array = [NSMutableArray array];
	[params enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
		NSPredicate *second = nil;
        if ([value isKindOfClass:[NSArray class]])
            second = [NSPredicate predicateWithFormat:@"%K IN %@", key, value];
        else
            second = [NSPredicate predicateWithFormat:@"%K == %@", key, value];
		[array addObject:second];
	}];
    [notParams enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
		NSPredicate *second = nil;
        if ([value isKindOfClass:[NSArray class]])
            second = [NSPredicate predicateWithFormat:@"NOT %K IN %@", key, value];
        else
            second = [NSPredicate predicateWithFormat:@"%K != %@", key, value];
		[array addObject:second];
	}];
	NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:array];
	NSFetchRequest *request = [NSFetchRequest new];
	request.entity = [NSEntityDescription entityForName:entity inManagedObjectContext:context];
	request.predicate = predicate;
	request.fetchLimit = 0;
	NSArray *objects = [context executeFetchRequest:request error:nil];
	[request release];
	return objects;
}

+ (NSArray *)objectsOfEntity:(NSEntityDescription *)entity withPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context
{
	NSFetchRequest *request = [NSFetchRequest new];
	request.entity = entity;
	request.predicate = predicate;
	request.fetchLimit = 0;
	NSArray *objects = [context executeFetchRequest:request error:nil];
	[request release];
	return objects;
}


#pragma mark Updading system

- (void)beginUpdatingObjectsOfEntity:(NSEntityDescription *)entity confirmingPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context
{
	// Достаем обновляемые объекты
	NSFetchRequest *request = [[NSFetchRequest new] autorelease];
	request.entity = entity;
	request.predicate = predicate;
	NSArray *newFetched = [context executeFetchRequest:request error:nil];
	// И сохраняем их для быстрого доступа
	NSArray *fetched = fetchedPacks[entity.name];
	if (fetched)
		fetchedPacks[entity.name] = [fetched arrayByAddingObjectsFromArray:newFetched];
	else
		fetchedPacks[entity.name] = newFetched;
	
	// Создаем массив для запоминания обновленных объектов
	if (!updatedPacks[entity.name])
		updatedPacks[entity.name] = [NSMutableSet set];
}

- (id)updatingObjectOfEntity:(NSEntityDescription *)entity confirmingPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context
{
	NSMutableSet *set = [updatedPacks objectForKey:entity.name];
	// Возвращаем обновляемый объект, который соответствует предикату
	NSArray *fetched = [fetchedPacks objectForKey:entity.name];
	NSArray *needed = [fetched filteredArrayUsingPredicate:predicate];
	id result = nil;
	// Если нужный объект найден, то возвращаем его
	if (needed.count > 0)
		result = needed[0];
	// Если объекта не было, то создаем его и запоминаем как обновленный
	else
		result = [[[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:context] autorelease];
	// Отмечаем объект, как обновленный
	[set addObject:result];
	return result;
}

- (void)endUpdatingObjectsOfEntity:(NSEntityDescription *)entity confirmingPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context
{
	NSSet *updated = [updatedPacks objectForKey:entity.name];
	if (!updated)
		return;
	
	if (predicate)
	{
		// Пересоздаем предикат, если множество редактированных объектов не пусто
		if (updated.count > 0)
			predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[predicate, [NSPredicate predicateWithFormat:@"NOT SELF IN %@", updated]]];
	}
	else if (updated.count > 0)
	{
		predicate = [NSPredicate predicateWithFormat:@"NOT SELF IN %@", updated];
	}
	
	NSArray *fetched = [fetchedPacks objectForKey:entity.name];
	NSArray *oldObjects = nil;
	if (fetched.count)
	{
		oldObjects = predicate ? [fetched filteredArrayUsingPredicate:predicate] : fetched;
		[oldObjects enumerateObjectsUsingBlock:^(NSManagedObject *obj, NSUInteger idx, BOOL *stop) {
			[context deleteObject:obj];
		}];
	}
	
	// После окончания действий с обновлением БД удаляем временные массивы
	NSLog(@"%@: Updated[%i], Deleted[%i]", entity.name, (int)updated.count, (int)oldObjects.count);
	[fetchedPacks removeObjectForKey:entity.name];
	[updatedPacks removeObjectForKey:entity.name];
}

/*
 Возвращает объект из БД и создает новый, если в БД его нет и нужно создать
 */
- (id)objectOfEntity:(NSEntityDescription *)entity confirmingPredicate:(NSPredicate *)predicate withValues:(NSDictionary *)values inContext:(NSManagedObjectContext *)context createIfAbsent:(BOOL)create
{
	NSFetchRequest *request = [[NSFetchRequest new] autorelease];
	request.entity = entity;
	// Задаем предикат запросу
	{
		NSPredicate *valuesPred = nil;
		if (values)
		{
			NSMutableArray *array = [NSMutableArray arrayWithCapacity:values.count];
			[values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
				NSPredicate *p = [NSPredicate predicateWithFormat:@"%K == %@", key, obj];
				[array addObject:p];
			}];
			valuesPred = [NSCompoundPredicate andPredicateWithSubpredicates:array];
		}
		if (valuesPred)
		{
			if (predicate)
				predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[predicate, valuesPred]];
			else
				predicate = valuesPred;
		}
		request.predicate = predicate;
	}
	
	NSArray *array = [context executeFetchRequest:request error:nil];
	if (array.count > 0)
	{
		return array[0];
	}
	else if (create)
	{
		NSManagedObject *obj = [[[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:context] autorelease];
		if (values)
			[obj setValuesForKeysWithDictionary:values];
		return obj;
	}
	return nil;
}

@end
