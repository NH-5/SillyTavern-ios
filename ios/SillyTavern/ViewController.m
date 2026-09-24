#import "ViewController.h"
#import "NodeRuntime.h"
#import <WebKit/WebKit.h>

@interface ViewController () <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, strong) NSMapTable<WKDownload *, NSURL *> *downloadURLs;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.14 alpha:1.0];
    self.downloadURLs = [NSMapTable strongToStrongObjectsMapTable];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.hidden = YES;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    self.loadingView = [[UIView alloc] init];
    self.loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingView];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color = UIColor.whiteColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [self.loadingView addSubview:spinner];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"正在启动 iPhone 本机服务…";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingView addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.loadingView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.loadingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [spinner.centerXAnchor constraintEqualToAnchor:self.loadingView.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.loadingView.centerYAnchor constant:-24],
        [self.statusLabel.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:20],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.loadingView.leadingAnchor constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.loadingView.trailingAnchor constant:-24],
    ]];

    [[NodeRuntime sharedRuntime] start];
    [self waitForServer];
}

- (void)waitForServer {
    if (self.pageLoaded) return;
    NSString *failure = [NodeRuntime sharedRuntime].failureMessage;
    if (failure) {
        self.statusLabel.text = failure;
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8000/api/ios/health"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)error;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ready = [http isKindOfClass:NSHTTPURLResponse.class] && http.statusCode == 200 &&
            [body isKindOfClass:NSDictionary.class] && [body[@"app"] isEqual:@"SillyTavern"] &&
            [body[@"platform"] isEqual:@"ios"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready) {
                [self loadLocalPage];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self waitForServer];
                });
            }
        });
    }];
    [task resume];
}

- (void)loadLocalPage {
    if (self.pageLoaded) return;
    self.pageLoaded = YES;
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8000/"];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    self.webView.hidden = NO;
    self.loadingView.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    self.statusLabel.text = [NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription];
    self.loadingView.hidden = NO;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    if (action.shouldPerformDownload) {
        decisionHandler(WKNavigationActionPolicyDownload);
        return;
    }
    NSURL *url = action.request.URL;
    BOOL local = [url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"];
    if (action.navigationType == WKNavigationTypeLinkActivated && !local &&
        ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    (void)webView;
    decisionHandler(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download {
    (void)webView;
    (void)action;
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download {
    (void)webView;
    (void)response;
    download.delegate = self;
}

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL *))completionHandler {
    (void)download;
    (void)response;
    NSString *filename = suggestedFilename.lastPathComponent.length ? suggestedFilename.lastPathComponent : @"SillyTavern-export";
    NSString *unique = [NSString stringWithFormat:@"%@-%@", [NSUUID UUID].UUIDString, filename];
    NSURL *destination = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:unique]];
    [self.downloadURLs setObject:destination forKey:download];
    completionHandler(destination);
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSURL *temporaryURL = [self.downloadURLs objectForKey:download];
    [self.downloadURLs removeObjectForKey:download];
    if (!temporaryURL) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[temporaryURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *error) {
        (void)activityType;
        (void)completed;
        (void)returnedItems;
        (void)error;
        [NSFileManager.defaultManager removeItemAtURL:temporaryURL error:nil];
    };
    [self presentViewController:share animated:YES completion:nil];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    (void)resumeData;
    NSURL *temporaryURL = [self.downloadURLs objectForKey:download];
    [self.downloadURLs removeObjectForKey:download];
    if (temporaryURL) [NSFileManager.defaultManager removeItemAtURL:temporaryURL error:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;
    NSURL *url = action.request.URL;
    if ([url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"] || [url.scheme isEqualToString:@"blob"]) {
        [self.webView loadRequest:action.request];
    } else if (url) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
    return nil;
}

@end
