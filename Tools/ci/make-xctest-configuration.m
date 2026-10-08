#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Xcode 27 の private API。生成もコンパイルも build job だけで行う。
// plist の手書きではなく、XCTestCore 自身の NSKeyedArchiver 形式を使う。
@interface NSObject (XCTConfigurationGeneration)
- (id)initWithStringRepresentation:(NSString *)value preserveModulePrefix:(BOOL)preserve;
- (id)initWithArray:(NSArray *)value;
@end

static id identifierSet(NSArray<NSString *> *names) {
    NSMutableArray *identifiers = [NSMutableArray array];
    Class cls = NSClassFromString(@"XCTTestIdentifier");
    for (NSString *name in names) {
        id identifier = [[cls alloc] initWithStringRepresentation:name preserveModulePrefix:YES];
        if (!identifier) [NSException raise:@"InvalidSelector" format:@"%@", name];
        [identifiers addObject:identifier];
    }
    return [[NSClassFromString(@"XCTTestIdentifierSet") alloc] initWithArray:identifiers];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr, "usage: make-xctest-configuration XCTestCore bundle selectors.json output\n");
            return 2;
        }
        if (!dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL)) {
            fprintf(stderr, "XCTestCore: %s\n", dlerror());
            return 1;
        }
        @try {
            NSError *error = nil;
            NSData *input = [NSData dataWithContentsOfFile:@(argv[3]) options:0 error:&error];
            NSDictionary *selectors = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:&error] : nil;
            if (!selectors || ![selectors[@"run"] isKindOfClass:NSArray.class] ||
                ![selectors[@"skip"] isKindOfClass:NSArray.class]) {
                NSLog(@"Invalid selectors: %@", error);
                return 1;
            }
            id config = [[NSClassFromString(@"XCTestConfiguration") alloc] init];
            if (!config) { NSLog(@"XCTestConfiguration is unavailable"); return 1; }
            [config setValue:[NSURL fileURLWithPath:@(argv[2])] forKey:@"testBundleURL"];
            [config setValue:@"KaitoFinderTests" forKey:@"productModuleName"];
            if ([selectors[@"run"] count]) [config setValue:identifierSet(selectors[@"run"]) forKey:@"testsToRun"];
            [config setValue:identifierSet(selectors[@"skip"]) forKey:@"testsToSkip"];
            [config setValue:@NO forKey:@"reportResultsToIDE"];
            [config setValue:@NO forKey:@"testsDrivenByIDE"];
            [config setValue:@NO forKey:@"inProcessParallelizationEnabled"];
            [config setValue:@YES forKey:@"testsMustRunOnMainThread"];
            [config setValue:@YES forKey:@"testTimeoutsEnabled"];
            [config setValue:@600 forKey:@"defaultTestExecutionTimeAllowance"];
            [config setValue:@600 forKey:@"maximumTestExecutionTimeAllowance"];
            NSLog(@"Direct-host configuration: %@", config);
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:config requiringSecureCoding:NO error:&error];
            if (!archive || ![archive writeToFile:@(argv[4]) options:NSDataWritingAtomic error:&error]) {
                NSLog(@"Configuration archive: %@", error);
                return 1;
            }
        } @catch (NSException *exception) {
            NSLog(@"Xcode XCTestConfiguration API changed: %@", exception);
            return 1;
        }
    }
    return 0;
}
