/*
 * XRG (X Resource Graph):  A system resource grapher for Mac OS X.
 * Copyright (C) 2002-2022 Gaucho Software, LLC.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 */

//
//  XRGAITokenMiner.m
//  Universal AI Token monitoring implementation
//

#import "XRGAITokenMiner.h"
#import "XRGAITokensObserver.h"
#import "definitions.h"
#import <sqlite3.h>

// ============================================================================
// MODEL PRICING DATABASE (per 1M tokens, USD)
// Updated: January 2026 - Dynamic per-model pricing
// Prices from official provider pricing pages
// ============================================================================

// Helper function to get model pricing
typedef struct {
    double inputPrice;   // $/MTok input
    double outputPrice;  // $/MTok output
} XRGModelPricing;

// Get pricing for a Claude model by name
static XRGModelPricing getClaudeModelPricing(NSString *modelName) {
    XRGModelPricing pricing = {3.0, 15.0}; // Default to Sonnet 4 pricing

    if (!modelName) return pricing;

    // Normalize model name to lowercase for matching
    NSString *model = [modelName lowercaseString];

    // Claude Opus 4.5 (claude-opus-4-5-*, claude-4.5-opus)
    if ([model containsString:@"opus-4-5"] || [model containsString:@"4-5-opus"] ||
        [model containsString:@"opus-4.5"] || [model containsString:@"4.5-opus"]) {
        pricing.inputPrice = 15.0;  pricing.outputPrice = 75.0;
    }
    // Claude Opus 4 (claude-opus-4-*, claude-4-opus)
    else if ([model containsString:@"opus-4"] || [model containsString:@"-4-opus"]) {
        pricing.inputPrice = 15.0;  pricing.outputPrice = 75.0;
    }
    // Claude Opus 3 (claude-3-opus)
    else if ([model containsString:@"3-opus"] || [model containsString:@"opus-3"]) {
        pricing.inputPrice = 15.0;  pricing.outputPrice = 75.0;
    }
    // Claude Sonnet 4 (claude-sonnet-4-*, claude-4-sonnet) - Current default
    else if ([model containsString:@"sonnet-4"] || [model containsString:@"-4-sonnet"]) {
        pricing.inputPrice = 3.0;   pricing.outputPrice = 15.0;
    }
    // Claude Sonnet 3.5 v2 (claude-3-5-sonnet-20241022)
    else if ([model containsString:@"3-5-sonnet"] || [model containsString:@"sonnet-3-5"] ||
             [model containsString:@"3.5-sonnet"] || [model containsString:@"sonnet-3.5"]) {
        pricing.inputPrice = 3.0;   pricing.outputPrice = 15.0;
    }
    // Claude Haiku 4.5 (claude-haiku-4-5-*)
    else if ([model containsString:@"haiku-4-5"] || [model containsString:@"4-5-haiku"] ||
             [model containsString:@"haiku-4.5"] || [model containsString:@"4.5-haiku"]) {
        pricing.inputPrice = 1.00;  pricing.outputPrice = 5.0;  // Haiku 4.5 pricing
    }
    // Claude Haiku 3.5 (claude-3-5-haiku)
    else if ([model containsString:@"3-5-haiku"] || [model containsString:@"haiku-3-5"] ||
             [model containsString:@"3.5-haiku"] || [model containsString:@"haiku-3.5"]) {
        pricing.inputPrice = 0.80;  pricing.outputPrice = 4.0;
    }
    // Claude Haiku 3 (claude-3-haiku)
    else if ([model containsString:@"3-haiku"] || [model containsString:@"haiku-3"]) {
        pricing.inputPrice = 0.25;  pricing.outputPrice = 1.25;
    }
    // Generic fallback by tier
    else if ([model containsString:@"opus"]) {
        pricing.inputPrice = 15.0;  pricing.outputPrice = 75.0;
    }
    else if ([model containsString:@"haiku"]) {
        pricing.inputPrice = 0.80;  pricing.outputPrice = 4.0;
    }
    // Default: Sonnet pricing (most common for Claude Code)

    return pricing;
}

// Get pricing for an OpenAI/Codex model by name.
// Not yet wired: the Codex path uses kCodexDefaultInputPrice/OutputPrice today
// (see the "model name parsing TODO" at the Codex/Gemini cost site). Kept and
// marked unused rather than deleted, so per-model Codex pricing is a lookup
// swap away when session records start carrying the model name.
__attribute__((unused))
static XRGModelPricing getCodexModelPricing(NSString *modelName) {
    XRGModelPricing pricing = {2.50, 10.0}; // Default to GPT-4o pricing

    if (!modelName) return pricing;

    NSString *model = [modelName lowercaseString];

    // o1 (reasoning model - premium)
    if ([model containsString:@"o1-preview"] || [model isEqualToString:@"o1"]) {
        pricing.inputPrice = 15.0;  pricing.outputPrice = 60.0;
    }
    // o1-mini (smaller reasoning)
    else if ([model containsString:@"o1-mini"]) {
        pricing.inputPrice = 3.0;   pricing.outputPrice = 12.0;
    }
    // o3-mini (newest reasoning)
    else if ([model containsString:@"o3-mini"]) {
        pricing.inputPrice = 1.10;  pricing.outputPrice = 4.40;
    }
    // GPT-4o (standard)
    else if ([model containsString:@"gpt-4o"] && ![model containsString:@"mini"]) {
        pricing.inputPrice = 2.50;  pricing.outputPrice = 10.0;
    }
    // GPT-4o-mini
    else if ([model containsString:@"gpt-4o-mini"]) {
        pricing.inputPrice = 0.15;  pricing.outputPrice = 0.60;
    }
    // GPT-4 Turbo
    else if ([model containsString:@"gpt-4-turbo"] || [model containsString:@"gpt-4-1106"]) {
        pricing.inputPrice = 10.0;  pricing.outputPrice = 30.0;
    }
    // GPT-4 (standard)
    else if ([model containsString:@"gpt-4"] && ![model containsString:@"turbo"]) {
        pricing.inputPrice = 30.0;  pricing.outputPrice = 60.0;
    }
    // GPT-3.5 Turbo
    else if ([model containsString:@"gpt-3.5"]) {
        pricing.inputPrice = 0.50;  pricing.outputPrice = 1.50;
    }
    // Codex specific models
    else if ([model containsString:@"codex"]) {
        pricing.inputPrice = 2.50;  pricing.outputPrice = 10.0;
    }

    return pricing;
}

// Get pricing for a Gemini model by name
static XRGModelPricing getGeminiModelPricing(NSString *modelName) {
    XRGModelPricing pricing = {0.10, 0.40}; // Default to Gemini 2.0 Flash pricing

    if (!modelName) return pricing;

    NSString *model = [modelName lowercaseString];

    // Gemini 2.0 Flash (current CLI default)
    if ([model containsString:@"2.0-flash"] || [model containsString:@"gemini-2.0"]) {
        pricing.inputPrice = 0.10;  pricing.outputPrice = 0.40;
    }
    // Gemini 1.5 Pro
    else if ([model containsString:@"1.5-pro"] || [model containsString:@"gemini-pro"]) {
        pricing.inputPrice = 1.25;  pricing.outputPrice = 5.0;
    }
    // Gemini 1.5 Flash
    else if ([model containsString:@"1.5-flash"]) {
        pricing.inputPrice = 0.075; pricing.outputPrice = 0.30;
    }
    // Gemini 1.0 Pro
    else if ([model containsString:@"1.0-pro"]) {
        pricing.inputPrice = 0.50;  pricing.outputPrice = 1.50;
    }
    // Gemini Ultra
    else if ([model containsString:@"ultra"]) {
        pricing.inputPrice = 10.0;  pricing.outputPrice = 30.0;
    }

    return pricing;
}

// Fallback constants (used when model name unknown or for estimation)
static const double kClaudeDefaultInputPrice = 3.0;   // Sonnet 4 (most common)
static const double kClaudeDefaultOutputPrice = 15.0;
static const double kCodexDefaultInputPrice = 2.50;   // GPT-4o (default)
static const double kCodexDefaultOutputPrice = 10.0;
static const double kGeminiDefaultInputPrice = 0.10;  // 2.0 Flash (default)
static const double kGeminiDefaultOutputPrice = 0.40;

@interface XRGAITokenMiner ()
- (NSData *)xrg_syncDataForRequest:(NSURLRequest *)request returningResponse:(NSHTTPURLResponse * _Nullable __autoreleasing *)response error:(NSError * _Nullable __autoreleasing *)error;
- (void)calculateCosts;
@end

@implementation XRGAITokenMiner

@synthesize totalClaudeTokens = _totalClaudeTokens;
@synthesize totalCodexTokens = _totalCodexTokens;
@synthesize totalGeminiTokens = _totalGeminiTokens;
@synthesize totalOllamaTokens = _totalOllamaTokens;
@synthesize totalHermesTokens = _totalHermesTokens;
@synthesize totalCostUSD = _totalCostUSD;
@synthesize activeStrategy;
@synthesize ollamaAvailable = _ollamaAvailable;
@synthesize ollamaRunningModels = _ollamaRunningModels;

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize data sets
        claudeCodeTokens = [[XRGDataSet alloc] init];
        codexTokens = [[XRGDataSet alloc] init];
        geminiTokens = [[XRGDataSet alloc] init];
        ollamaTokens = [[XRGDataSet alloc] init];
        hermesTokens = [[XRGDataSet alloc] init];
        costPerSecond = [[XRGDataSet alloc] init];

        // Initialize counters
        _totalClaudeTokens = 0;
        _totalCodexTokens = 0;
        _totalGeminiTokens = 0;
        _totalOllamaTokens = 0;
        _totalHermesTokens = 0;
        _totalCostUSD = 0.0;
        lastClaudeCount = 0;
        lastCodexCount = 0;
        lastGeminiCount = 0;
        lastGeminiInputCount = 0;
        lastGeminiOutputCount = 0;
        lastOllamaCount = 0;
        lastHermesCount = 0;
        lastTotalCost = 0.0;

        // Initialize input/output token counters for cost calculation
        claudeInputTokens = 0;
        claudeOutputTokens = 0;
        codexInputTokens = 0;
        codexOutputTokens = 0;
        geminiInputTokens = 0;
        geminiOutputTokens = 0;
        ollamaInputTokens = 0;
        ollamaOutputTokens = 0;
        hermesInputTokens = 0;
        hermesOutputTokens = 0;
        hermesCostUSD = 0.0;

        // Initialize current rates
        currentClaudeRate = 0;
        currentCodexRate = 0;
        currentGeminiRate = 0;
        currentOllamaRate = 0;
        currentHermesRate = 0;
        currentCostRate = 0.0;

        // Initialize Ollama API tracking
        ollamaApiEndpoint = @"http://localhost:11434";
        _ollamaAvailable = NO;
        ollamaAvailableModels = @[];
        _ollamaRunningModels = @[];
        lastOllamaScanTime = nil;
        cachedOllamaTokens = 0;

        // Initialize paths
        NSString *homeDir = NSHomeDirectory();
        jsonlProjectsPath = [homeDir stringByAppendingPathComponent:@".claude/projects"];
        codexSessionsPath = [homeDir stringByAppendingPathComponent:@".codex/sessions"];
        geminiTmpPath = [homeDir stringByAppendingPathComponent:@".gemini/tmp"];
        dbPath = [homeDir stringByAppendingPathComponent:@".claude/monitoring/claude_usage.db"];
        otelEndpoint = @"http://localhost:8889/metrics";
        hermesDbPath = [homeDir stringByAppendingPathComponent:@".hermes/state.db"];

        // Initialize caches for performance
        jsonlFileModTimes = [[NSMutableDictionary alloc] init];
        geminiFileModTimes = [[NSMutableDictionary alloc] init];
        cachedJSONLTokens = 0;
        cachedCodexTokens = 0;
        cachedGeminiTokens = 0;

        // Initialize cached input/output tokens
        cachedClaudeInputTokens = 0;
        cachedClaudeOutputTokens = 0;
        cachedCodexInputTokens = 0;
        cachedCodexOutputTokens = 0;
        cachedGeminiInputTokens = 0;
        cachedGeminiOutputTokens = 0;

        // Initialize per-model cost tracking
        claudeModelCosts = [[NSMutableDictionary alloc] init];
        cachedClaudeCost = 0.0;
        geminiModelCosts = [[NSMutableDictionary alloc] init];
        cachedGeminiCost = 0.0;

        // Hermes per-model tracking
        hermesModelTokens = [[NSMutableDictionary alloc] init];
        hermesTopModel = nil;

        lastJSONLScanTime = nil;
        lastCodexScanTime = nil;
        lastGeminiScanTime = nil;

        // Create background queue for non-blocking file operations
        jsonlParsingQueue = dispatch_queue_create("com.xrg.jsonl.parsing", DISPATCH_QUEUE_SERIAL);
        cacheSemaphore = dispatch_semaphore_create(1);

        // Detect best data collection strategy (for Claude)
        [self detectBestStrategy];

        // DON'T call getLatestTokenInfo during init - it could block!
        // Instead, start with zeros and let the first graphUpdate call handle it

        // Trigger immediate background cache build for all providers.
        // self-> is explicit: this one-shot startup block accesses an ivar and
        // the miner outlives the block, so the retain is intended, not a cycle.
        dispatch_async(jsonlParsingQueue, ^{
            if (self->activeStrategy == XRGAIDataStrategyJSONL) {
                [self updateJSONLCacheInBackground];
            }
            [self updateCodexCacheInBackground];
            [self updateGeminiCacheInBackground];
            [self updateOllamaStatusInBackground];
        });

#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Initialized with strategy: %@", [self strategyName]);
#endif
    }

    return self;
}

- (void)setDataSize:(int)newNumSamples {
    if (newNumSamples < 0) return;

    if (claudeCodeTokens && codexTokens && geminiTokens && ollamaTokens && hermesTokens && costPerSecond) {
        [claudeCodeTokens resize:(size_t)newNumSamples];
        [codexTokens resize:(size_t)newNumSamples];
        [geminiTokens resize:(size_t)newNumSamples];
        [ollamaTokens resize:(size_t)newNumSamples];
        [hermesTokens resize:(size_t)newNumSamples];
        [costPerSecond resize:(size_t)newNumSamples];
    }
    else {
        claudeCodeTokens = [[XRGDataSet alloc] init];
        codexTokens = [[XRGDataSet alloc] init];
        geminiTokens = [[XRGDataSet alloc] init];
        ollamaTokens = [[XRGDataSet alloc] init];
        hermesTokens = [[XRGDataSet alloc] init];
        costPerSecond = [[XRGDataSet alloc] init];

        [claudeCodeTokens resize:(size_t)newNumSamples];
        [codexTokens resize:(size_t)newNumSamples];
        [geminiTokens resize:(size_t)newNumSamples];
        [ollamaTokens resize:(size_t)newNumSamples];
        [hermesTokens resize:(size_t)newNumSamples];
        [costPerSecond resize:(size_t)newNumSamples];
    }

    numSamples = newNumSamples;
}

- (void)reset {
    [claudeCodeTokens reset];
    [codexTokens reset];
    [geminiTokens reset];
    [ollamaTokens reset];
    [hermesTokens reset];
    [costPerSecond reset];

    _totalClaudeTokens = 0;
    _totalCodexTokens = 0;
    _totalGeminiTokens = 0;
    _totalOllamaTokens = 0;
    _totalHermesTokens = 0;
    _totalCostUSD = 0.0;
    lastClaudeCount = 0;
    lastCodexCount = 0;
    lastGeminiCount = 0;
    lastGeminiInputCount = 0;
    lastGeminiOutputCount = 0;
    lastOllamaCount = 0;
    lastHermesCount = 0;
    lastTotalCost = 0.0;

    // Reset input/output token counters
    claudeInputTokens = 0;
    claudeOutputTokens = 0;
    codexInputTokens = 0;
    codexOutputTokens = 0;
    geminiInputTokens = 0;
    geminiOutputTokens = 0;
    ollamaInputTokens = 0;
    ollamaOutputTokens = 0;
    hermesInputTokens = 0;
    hermesOutputTokens = 0;
    hermesCostUSD = 0.0;

    currentClaudeRate = 0;
    currentCodexRate = 0;
    currentGeminiRate = 0;
    currentOllamaRate = 0;
    currentHermesRate = 0;
    currentCostRate = 0.0;

    // Reset model costs
    [claudeModelCosts removeAllObjects];
    cachedClaudeCost = 0.0;
    [geminiModelCosts removeAllObjects];
    cachedGeminiCost = 0.0;

    // Reset Hermes per-model tracking
    [hermesModelTokens removeAllObjects];
    hermesTopModel = nil;

    // Reset Ollama state
    _ollamaAvailable = NO;
    _ollamaRunningModels = @[];
    cachedOllamaTokens = 0;
}

- (void)detectBestStrategy {
    // Try strategies in priority order until one works
    // NOTE: This method should be fast and non-blocking!

    // Strategy 1: JSONL transcripts (universal - works for EVERYONE with default Claude Code)
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:jsonlProjectsPath]) {
        activeStrategy = XRGAIDataStrategyJSONL;
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Using JSONL strategy: %@", jsonlProjectsPath);
#endif
        return;
    }

    // Strategy 2: SQLite database (advanced - custom monitoring setup)
    if ([fm fileExistsAtPath:dbPath]) {
        activeStrategy = XRGAIDataStrategySQLite;
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Using SQLite strategy: %@", dbPath);
#endif
        return;
    }

    // Strategy 3: OpenTelemetry endpoint (advanced - OTel configured)
    // SKIP network check during initialization - too slow!
    // Will be attempted on first getLatestTokenInfo() call if needed
    
    // No file-based strategy available - default to None
    // (OTel will be tried later if needed)
    activeStrategy = XRGAIDataStrategyNone;
#ifdef XRG_DEBUG
    NSLog(@"[XRGAITokenMiner] No file-based strategy found, will try OTel on first update");
#endif
}

- (NSString *)strategyName {
    switch (activeStrategy) {
        case XRGAIDataStrategyJSONL:
            return @"JSONL Transcripts (Universal - Default Claude Code)";
        case XRGAIDataStrategySQLite:
            return @"SQLite Database (Advanced - Custom Monitoring)";
        case XRGAIDataStrategyOTel:
            return @"OpenTelemetry Endpoint (Advanced - OTel Configured)";
        default:
            return @"None (No data available)";
    }
}

- (void)getLatestTokenInfo {
    BOOL success = NO;

    // === Fetch Claude Code tokens ===
    switch (activeStrategy) {
        case XRGAIDataStrategyJSONL:
            success = [self fetchFromJSONLTranscripts];
            break;
        case XRGAIDataStrategySQLite:
            success = [self fetchFromSQLiteDatabase];
            break;
        case XRGAIDataStrategyOTel: {
            success = [self fetchFromOTelEndpoint];
            break;
        }
        default:
            break;
    }

    // If active strategy failed, try to detect a new strategy
    if (!success && activeStrategy != XRGAIDataStrategyNone) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Active strategy failed, re-detecting...");
#endif
        [self detectBestStrategy];
    }

    // === Fetch Codex CLI tokens ===
    [self fetchFromCodexCLI];

    // === Fetch Gemini CLI tokens ===
    [self fetchFromGeminiCLI];

    // === Fetch Ollama local inference status ===
    [self fetchFromOllamaAPI];

    // === Fetch Hermes agent tokens (SQLite ~/.hermes/state.db) ===
    [self fetchFromHermesDatabase];

    // Calculate rates (delta from last update) - CRITICAL: Calculate BEFORE updating lastCount
    currentClaudeRate = (UInt32)(_totalClaudeTokens - lastClaudeCount);
    currentCodexRate = (UInt32)(_totalCodexTokens - lastCodexCount);
    currentGeminiRate = (UInt32)(_totalGeminiTokens - lastGeminiCount);
    currentOllamaRate = (UInt32)(_totalOllamaTokens - lastOllamaCount);
    currentHermesRate = (UInt32)(_totalHermesTokens - lastHermesCount);

    // Record events for budget tracking
    if (currentGeminiRate > 0) {
        UInt64 inputDelta = geminiInputTokens - lastGeminiInputCount;
        UInt64 outputDelta = geminiOutputTokens - lastGeminiOutputCount;
        [[XRGAITokensObserver shared] recordEventWithPromptTokens:(NSUInteger)inputDelta
                                                 completionTokens:(NSUInteger)outputDelta
                                                            model:@"Gemini"
                                                         provider:@"Google"];
    }

    // Update last counts
    lastClaudeCount = _totalClaudeTokens;
    lastCodexCount = _totalCodexTokens;
    lastGeminiCount = _totalGeminiTokens;
    lastGeminiInputCount = geminiInputTokens;
    lastGeminiOutputCount = geminiOutputTokens;
    lastOllamaCount = _totalOllamaTokens;
    lastHermesCount = _totalHermesTokens;

    // Store rates in data sets
    if (claudeCodeTokens) [claudeCodeTokens setNextValue:currentClaudeRate];
    if (codexTokens) [codexTokens setNextValue:currentCodexRate];
    if (geminiTokens) [geminiTokens setNextValue:currentGeminiRate];
    if (ollamaTokens) [ollamaTokens setNextValue:currentOllamaRate];
    if (hermesTokens) [hermesTokens setNextValue:currentHermesRate];

    // === Calculate costs ===
    [self calculateCosts];

    // Calculate cost rate ($/second) - CRITICAL: Calculate BEFORE updating lastTotalCost
    currentCostRate = _totalCostUSD - lastTotalCost;
    lastTotalCost = _totalCostUSD;

    // Store cost rate in data set (scaled by 1000 for visibility in graph)
    if (costPerSecond) [costPerSecond setNextValue:(CGFloat)(currentCostRate * 1000.0)];
}

#pragma mark - Strategy 1: SQLite Database (Universal)

- (BOOL)fetchFromSQLiteDatabase {
    sqlite3 *db = NULL;
    int rc = sqlite3_open([dbPath UTF8String], &db);

    if (rc != SQLITE_OK) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Failed to open database: %s", sqlite3_errmsg(db));
#endif
        sqlite3_close(db);
        return NO;
    }

    // Query for total tokens and cost
    const char *sql = "SELECT SUM(tokens_used) as total_tokens, SUM(estimated_cost) as total_cost FROM sessions WHERE tokens_used > 0";
    sqlite3_stmt *stmt = NULL;

    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Failed to prepare statement: %s", sqlite3_errmsg(db));
#endif
        sqlite3_close(db);
        return NO;
    }

    if (sqlite3_step(stmt) == SQLITE_ROW) {
        _totalClaudeTokens = (UInt64)sqlite3_column_int64(stmt, 0);
        _totalCostUSD = sqlite3_column_double(stmt, 1);

#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] SQLite: tokens=%llu, cost=$%.4f", _totalClaudeTokens, _totalCostUSD);
#endif
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);

    return YES;
}

#pragma mark - Hermes Agent (SQLite ~/.hermes/state.db)

// Read Hermes token/model/cost stats from its SQLite state DB.
//
// The Hermes `sessions` table records, per session: the model used, the
// input/output token split, and a cost Hermes computes itself
// (actual_cost_usd, falling back to estimated_cost_usd). We aggregate across
// all sessions and build a per-model breakdown so the models we run in Hermes
// (e.g. MiniMax-M3) are visible in XRG. Opened read-only + immutable so XRG
// never blocks or interferes with a live Hermes holding the DB open (WAL mode).
- (BOOL)fetchFromHermesDatabase {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:hermesDbPath]) {
        return NO;
    }

    NSString *uri = [NSString stringWithFormat:@"file:%@?immutable=1&mode=ro", hermesDbPath];
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2([uri UTF8String], &db,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
    if (rc != SQLITE_OK) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Failed to open Hermes DB: %s", db ? sqlite3_errmsg(db) : "(null)");
#endif
        if (db) sqlite3_close(db);
        return NO;
    }

    const char *sql =
        "SELECT model, "
        "       SUM(COALESCE(input_tokens,0)), "
        "       SUM(COALESCE(output_tokens,0)), "
        "       SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)) "
        "FROM sessions "
        "WHERE model IS NOT NULL AND model != '' "
        "GROUP BY model";

    sqlite3_stmt *stmt = NULL;
    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Failed to prepare Hermes statement: %s", sqlite3_errmsg(db));
#endif
        sqlite3_close(db);
        return NO;
    }

    UInt64 totalInput = 0, totalOutput = 0;
    double totalCost = 0.0;
    UInt64 mostUsedTokens = 0;
    NSString *topModel = nil;
    NSMutableDictionary *models = [[NSMutableDictionary alloc] init];

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *modelText = sqlite3_column_text(stmt, 0);
        UInt64 input = (UInt64)sqlite3_column_int64(stmt, 1);
        UInt64 output = (UInt64)sqlite3_column_int64(stmt, 2);
        double cost = sqlite3_column_double(stmt, 3);

        totalInput += input;
        totalOutput += output;
        totalCost += cost;

        if (modelText) {
            NSString *model = [NSString stringWithUTF8String:(const char *)modelText];
            if (model) {
                models[model] = @{@"input": @(input), @"output": @(output)};
                UInt64 modelTotal = input + output;
                if (modelTotal > mostUsedTokens) {
                    mostUsedTokens = modelTotal;
                    topModel = model;
                }
            }
        }
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);

    hermesInputTokens = totalInput;
    hermesOutputTokens = totalOutput;
    _totalHermesTokens = totalInput + totalOutput;
    hermesCostUSD = totalCost;
    hermesModelTokens = models;
    hermesTopModel = topModel;

#ifdef XRG_DEBUG
    NSLog(@"[XRGAITokenMiner] Hermes: tokens=%llu, topModel=%@, cost=$%.4f",
          _totalHermesTokens, topModel, totalCost);
#endif

    return YES;
}

#pragma mark - Strategy 2: OpenTelemetry Endpoint (Advanced)

- (BOOL)fetchFromOTelEndpoint {
    NSURL *url = [NSURL URLWithString:otelEndpoint];
    if (!url) return NO;

    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:2.0];

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [self xrg_syncDataForRequest:request returningResponse:&response error:&error];

    if (error || !data || response.statusCode != 200) {
#ifdef XRG_DEBUG
        if (error) NSLog(@"[XRGAITokenMiner] OTel error: %@", error);
#endif
        return NO;
    }

    NSString *metricsText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!metricsText) return NO;

    // Parse Prometheus format metrics
    [self parsePrometheusMetrics:metricsText];
    return YES;
}

- (void)parsePrometheusMetrics:(NSString *)metricsText {
    NSArray *lines = [metricsText componentsSeparatedByString:@"\n"];

    UInt64 inputTokens = 0;
    UInt64 outputTokens = 0;
    UInt64 cacheReadTokens = 0;
    UInt64 cacheCreateTokens = 0;
    double costUSD = 0.0;

    for (NSString *line in lines) {
        if ([line hasPrefix:@"#"] || [line length] == 0) continue;

        if ([line containsString:@"token_usage"] || [line containsString:@"tokens"]) {
            if ([line containsString:@"input"]) {
                inputTokens += [self extractValueFromMetricLine:line];
            }
            else if ([line containsString:@"output"]) {
                outputTokens += [self extractValueFromMetricLine:line];
            }
            else if ([line containsString:@"cache_read"]) {
                cacheReadTokens += [self extractValueFromMetricLine:line];
            }
            else if ([line containsString:@"cache_create"]) {
                cacheCreateTokens += [self extractValueFromMetricLine:line];
            }
        }
        else if ([line containsString:@"cost"]) {
            costUSD += [self extractDoubleValueFromMetricLine:line];
        }
    }

    _totalClaudeTokens = inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens;
    _totalCostUSD = costUSD;
}

- (UInt64)extractValueFromMetricLine:(NSString *)line {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSMutableArray *nonEmptyParts = [NSMutableArray array];
    for (NSString *part in parts) {
        if ([part length] > 0) [nonEmptyParts addObject:part];
    }

    if ([nonEmptyParts count] >= 2) {
        NSString *valueStr = nonEmptyParts[[nonEmptyParts count] - 2];
        return (UInt64)[valueStr longLongValue];
    }
    return 0;
}

- (double)extractDoubleValueFromMetricLine:(NSString *)line {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSMutableArray *nonEmptyParts = [NSMutableArray array];
    for (NSString *part in parts) {
        if ([part length] > 0) [nonEmptyParts addObject:part];
    }

    if ([nonEmptyParts count] >= 2) {
        NSString *valueStr = nonEmptyParts[[nonEmptyParts count] - 2];
        return [valueStr doubleValue];
    }
    return 0.0;
}

#pragma mark - Strategy 1: JSONL Transcripts (Universal)

- (BOOL)fetchFromJSONLTranscripts {
    // CRITICAL: Return immediately with cached value (non-blocking!)
    // File operations happen asynchronously on background queue

    // Thread-safe read of cached values (including input/output AND per-model costs)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    _totalClaudeTokens = cachedJSONLTokens;
    claudeInputTokens = cachedClaudeInputTokens;
    claudeOutputTokens = cachedClaudeOutputTokens;
    // Use per-model calculated cost (not estimated from defaults)
    double perModelCost = cachedClaudeCost;
    dispatch_semaphore_signal(cacheSemaphore);

    // Store the per-model cost for use in claudeCostUSD
    claudeModelCosts[@"_total"] = @(perModelCost);

    // Check if we should trigger background update
    NSDate *now = [NSDate date];
    BOOL shouldUpdate = NO;

    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);

    // Trigger update if:
    // 1. First time (no last scan time)
    // 2. Been more than 30 seconds since last scan
    // NOTE: With 26K+ JSONL files, scanning more frequently causes 100% CPU!
    // The 1-second throttle was too aggressive for large file counts.
    if (!lastJSONLScanTime || [now timeIntervalSinceDate:lastJSONLScanTime] > 30.0) {
        shouldUpdate = YES;
        lastJSONLScanTime = now; // Prevent multiple simultaneous updates
    }
    dispatch_semaphore_signal(cacheSemaphore);

    // Dispatch background update (non-blocking)
    if (shouldUpdate) {
        dispatch_async(jsonlParsingQueue, ^{
            [self updateJSONLCacheInBackground];
        });
    }

    return YES; // Always succeeds (returns cached value immediately)
}

// Background thread method - does all the heavy file I/O
- (void)updateJSONLCacheInBackground {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    // Get all project directories in ~/.claude/projects/
    NSArray *projects = [fm contentsOfDirectoryAtPath:jsonlProjectsPath error:&error];
    if (error || !projects) {
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Cannot access JSONL projects path: %@", jsonlProjectsPath);
#endif
        return;
    }

    // Thread-safe read of current cache
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    UInt64 totalTokens = cachedJSONLTokens;
    UInt64 totalInputTokens = cachedClaudeInputTokens;
    UInt64 totalOutputTokens = cachedClaudeOutputTokens;
    double totalCost = cachedClaudeCost;
    NSMutableDictionary *modTimes = [jsonlFileModTimes mutableCopy]; // Work on copy
    dispatch_semaphore_signal(cacheSemaphore);

    BOOL anyChanges = NO;

    // Scan all project directories (on background thread - won't block UI)
    for (NSString *projectName in projects) {
        NSString *projectPath = [jsonlProjectsPath stringByAppendingPathComponent:projectName];

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:projectPath isDirectory:&isDir] || !isDir) {
            continue;
        }

        NSArray *files = [fm contentsOfDirectoryAtPath:projectPath error:nil];
        if (!files) continue;

        for (NSString *filename in files) {
            if ([filename hasSuffix:@".jsonl"]) {
                NSString *filePath = [projectPath stringByAppendingPathComponent:filename];

                NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
                if (!attrs) continue;

                NSDate *modTime = attrs[NSFileModificationDate];
                NSDate *cachedModTime = modTimes[filePath];

                // Skip unchanged files
                if (cachedModTime && [modTime isEqualToDate:cachedModTime]) {
                    continue;
                }

                // File is new or modified - parse it
                anyChanges = YES;

                // Subtract old values if file was previously cached
                NSNumber *oldFileTokens = modTimes[[filePath stringByAppendingString:@"_tokens"]];
                NSNumber *oldInputTokens = modTimes[[filePath stringByAppendingString:@"_input"]];
                NSNumber *oldOutputTokens = modTimes[[filePath stringByAppendingString:@"_output"]];
                NSNumber *oldFileCost = modTimes[[filePath stringByAppendingString:@"_cost"]];
                if (oldFileTokens) {
                    totalTokens -= [oldFileTokens unsignedLongLongValue];
                }
                if (oldInputTokens) {
                    totalInputTokens -= [oldInputTokens unsignedLongLongValue];
                }
                if (oldOutputTokens) {
                    totalOutputTokens -= [oldOutputTokens unsignedLongLongValue];
                }
                if (oldFileCost) {
                    totalCost -= [oldFileCost doubleValue];
                }

                // Parse this file with input/output tracking AND per-model costs
                UInt64 fileInputTokens = 0;
                UInt64 fileOutputTokens = 0;
                double fileCostIn = 0.0;
                double fileCostOut = 0.0;
                UInt64 fileTokens = [self parseJSONLFile:filePath
                                             inputTokens:&fileInputTokens
                                            outputTokens:&fileOutputTokens
                                             modelCostIn:&fileCostIn
                                            modelCostOut:&fileCostOut];

                double fileCost = fileCostIn + fileCostOut;
                totalTokens += fileTokens;
                totalInputTokens += fileInputTokens;
                totalOutputTokens += fileOutputTokens;
                totalCost += fileCost;

                // Update local copy of cache
                modTimes[filePath] = modTime;
                modTimes[[filePath stringByAppendingString:@"_tokens"]] = @(fileTokens);
                modTimes[[filePath stringByAppendingString:@"_input"]] = @(fileInputTokens);
                modTimes[[filePath stringByAppendingString:@"_output"]] = @(fileOutputTokens);
                modTimes[[filePath stringByAppendingString:@"_cost"]] = @(fileCost);
            }
        }
    }

    // Thread-safe update of cache (only if changes detected)
    if (anyChanges) {
        dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
        cachedJSONLTokens = totalTokens;
        cachedClaudeInputTokens = totalInputTokens;
        cachedClaudeOutputTokens = totalOutputTokens;
        cachedClaudeCost = totalCost;
        jsonlFileModTimes = modTimes; // Replace with updated copy
        dispatch_semaphore_signal(cacheSemaphore);

#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] JSONL cache updated: total=%llu input=%llu output=%llu cost=$%.4f",
              totalTokens, totalInputTokens, totalOutputTokens, totalCost);
#endif
    }
}

// Helper method to parse a single JSONL file using streaming (memory efficient)
// Returns total tokens, optionally outputs input/output breakdown and per-model costs
- (UInt64)parseJSONLFile:(NSString *)filePath
             inputTokens:(UInt64 *)outInputTokens
            outputTokens:(UInt64 *)outOutputTokens
             modelCostIn:(double *)outModelCostIn
            modelCostOut:(double *)outModelCostOut {
    FILE *file = fopen([filePath UTF8String], "r");
    if (!file) {
        if (outInputTokens) *outInputTokens = 0;
        if (outOutputTokens) *outOutputTokens = 0;
        if (outModelCostIn) *outModelCostIn = 0.0;
        if (outModelCostOut) *outModelCostOut = 0.0;
        return 0;
    }

    UInt64 fileTokens = 0;
    UInt64 fileInputTokens = 0;
    UInt64 fileOutputTokens = 0;
    double fileCostIn = 0.0;
    double fileCostOut = 0.0;
    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;

    // Read file line-by-line to minimize memory usage
    // This avoids loading 443MB+ of JSONL files into memory at once
    while ((linelen = getline(&line, &linecap, file)) > 0) {
        if (linelen <= 1) continue;  // Skip empty lines

        @autoreleasepool {
            NSData *jsonData = [NSData dataWithBytesNoCopy:line length:linelen freeWhenDone:NO];
            NSError *parseError = nil;
            NSDictionary *data = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                options:0
                                                                  error:&parseError];

            // Extract token usage from message.usage
            if (!data || [data isKindOfClass:[NSNull class]]) continue;
            NSDictionary *message = data[@"message"];
            if (!message || [message isKindOfClass:[NSNull class]]) continue;

            // Extract model name for accurate pricing
            NSString *modelName = message[@"model"];

            NSDictionary *usage = message[@"usage"];
            if (usage && ![usage isKindOfClass:[NSNull class]]) {
                // Calculate prompt and completion tokens
                UInt64 promptTokens = [usage[@"input_tokens"] unsignedLongLongValue] +
                                     [usage[@"cache_creation_input_tokens"] unsignedLongLongValue] +
                                     [usage[@"cache_read_input_tokens"] unsignedLongLongValue];
                UInt64 completionTokens = [usage[@"output_tokens"] unsignedLongLongValue];

                fileInputTokens += promptTokens;
                fileOutputTokens += completionTokens;
                fileTokens += promptTokens + completionTokens;

                // Calculate cost using actual model pricing
                XRGModelPricing pricing = getClaudeModelPricing(modelName);
                fileCostIn += (promptTokens / 1000000.0) * pricing.inputPrice;
                fileCostOut += (completionTokens / 1000000.0) * pricing.outputPrice;
            }
        }
    }

    free(line);
    fclose(file);

    if (outInputTokens) *outInputTokens = fileInputTokens;
    if (outOutputTokens) *outOutputTokens = fileOutputTokens;
    if (outModelCostIn) *outModelCostIn = fileCostIn;
    if (outModelCostOut) *outModelCostOut = fileCostOut;

    return fileTokens;
}

// Wrapper for backward compatibility
- (UInt64)parseJSONLFile:(NSString *)filePath
             inputTokens:(UInt64 *)outInputTokens
            outputTokens:(UInt64 *)outOutputTokens {
    return [self parseJSONLFile:filePath
                    inputTokens:outInputTokens
                   outputTokens:outOutputTokens
                    modelCostIn:NULL
                   modelCostOut:NULL];
}

// Legacy method for backward compatibility
- (UInt64)parseJSONLFile:(NSString *)filePath {
    return [self parseJSONLFile:filePath inputTokens:NULL outputTokens:NULL];
}

#pragma mark - Codex CLI Methods

- (BOOL)fetchFromCodexCLI {
    // CRITICAL: Return immediately with cached value (non-blocking!)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    _totalCodexTokens = cachedCodexTokens;
    dispatch_semaphore_signal(cacheSemaphore);

    // Check if we should trigger background update (throttled)
    NSDate *now = [NSDate date];
    BOOL shouldUpdate = NO;

    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    // Throttle to every 30 seconds to avoid excessive file I/O
    if (!lastCodexScanTime || [now timeIntervalSinceDate:lastCodexScanTime] > 30.0) {
        shouldUpdate = YES;
        lastCodexScanTime = now;
    }
    dispatch_semaphore_signal(cacheSemaphore);

    // Dispatch background update (non-blocking)
    if (shouldUpdate) {
        dispatch_async(jsonlParsingQueue, ^{
            [self updateCodexCacheInBackground];
        });
    }

    return YES;
}

- (void)updateCodexCacheInBackground {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:codexSessionsPath]) {
        return;
    }

    UInt64 totalTokens = 0;

    // Traverse YYYY/MM/DD directory structure
    NSArray *years = [fm contentsOfDirectoryAtPath:codexSessionsPath error:nil];
    if (!years) return;

    for (NSString *year in years) {
        NSString *yearPath = [codexSessionsPath stringByAppendingPathComponent:year];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:yearPath isDirectory:&isDir] || !isDir) continue;

        NSArray *months = [fm contentsOfDirectoryAtPath:yearPath error:nil];
        if (!months) continue;

        for (NSString *month in months) {
            NSString *monthPath = [yearPath stringByAppendingPathComponent:month];
            if (![fm fileExistsAtPath:monthPath isDirectory:&isDir] || !isDir) continue;

            NSArray *days = [fm contentsOfDirectoryAtPath:monthPath error:nil];
            if (!days) continue;

            for (NSString *day in days) {
                NSString *dayPath = [monthPath stringByAppendingPathComponent:day];
                if (![fm fileExistsAtPath:dayPath isDirectory:&isDir] || !isDir) continue;

                NSArray *files = [fm contentsOfDirectoryAtPath:dayPath error:nil];
                if (!files) continue;

                for (NSString *filename in files) {
                    if ([filename hasPrefix:@"rollout-"] && [filename hasSuffix:@".jsonl"]) {
                        NSString *filePath = [dayPath stringByAppendingPathComponent:filename];
                        totalTokens += [self parseCodexJSONLFile:filePath];
                    }
                }
            }
        }
    }

    // Thread-safe update of cache
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    cachedCodexTokens = totalTokens;
    dispatch_semaphore_signal(cacheSemaphore);

#ifdef XRG_DEBUG
    if (totalTokens > 0) {
        NSLog(@"[XRGAITokenMiner] Codex cache updated: tokens=%llu", totalTokens);
    }
#endif
}

// Memory-efficient streaming parser for Codex JSONL files
- (UInt64)parseCodexJSONLFile:(NSString *)filePath {
    FILE *file = fopen([filePath UTF8String], "r");
    if (!file) return 0;

    UInt64 lastTotal = 0;
    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;

    while ((linelen = getline(&line, &linecap, file)) > 0) {
        if (linelen <= 1) continue;

        @autoreleasepool {
            NSData *jsonData = [NSData dataWithBytesNoCopy:line length:linelen freeWhenDone:NO];
            NSDictionary *data = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
            if (!data) continue;

            if (![data[@"type"] isEqualToString:@"event_msg"]) continue;

            NSDictionary *payload = data[@"payload"];
            if (!payload || [payload isKindOfClass:[NSNull class]]) continue;
            if (![payload[@"type"] isEqualToString:@"token_count"]) continue;

            NSDictionary *info = payload[@"info"];
            if (!info || [info isKindOfClass:[NSNull class]]) continue;

            NSDictionary *totalUsage = info[@"total_token_usage"];
            if (!totalUsage || [totalUsage isKindOfClass:[NSNull class]]) continue;

            if (totalUsage[@"total_tokens"]) {
                lastTotal = [totalUsage[@"total_tokens"] unsignedLongLongValue];
            } else {
                UInt64 input = [totalUsage[@"input_tokens"] unsignedLongLongValue];
                UInt64 output = [totalUsage[@"output_tokens"] unsignedLongLongValue];
                lastTotal = input + output;
            }
        }
    }

    free(line);
    fclose(file);

    return lastTotal;
}

#pragma mark - Gemini CLI Methods

- (BOOL)fetchFromGeminiCLI {
    // CRITICAL: Return immediately with cached value (non-blocking!)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    _totalGeminiTokens = cachedGeminiTokens;
    geminiInputTokens = cachedGeminiInputTokens;
    geminiOutputTokens = cachedGeminiOutputTokens;
    dispatch_semaphore_signal(cacheSemaphore);

    // Check if we should trigger background update (throttled)
    NSDate *now = [NSDate date];
    BOOL shouldUpdate = NO;

    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    // Throttle to every 30 seconds to avoid excessive file I/O
    if (!lastGeminiScanTime || [now timeIntervalSinceDate:lastGeminiScanTime] > 30.0) {
        shouldUpdate = YES;
        lastGeminiScanTime = now;
    }
    dispatch_semaphore_signal(cacheSemaphore);

    // Dispatch background update (non-blocking)
    if (shouldUpdate) {
        dispatch_async(jsonlParsingQueue, ^{
            [self updateGeminiCacheInBackground];
        });
    }

    return YES;
}

- (void)updateGeminiCacheInBackground {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:geminiTmpPath]) {
        return;
    }

    // Get current cache state (thread-safe)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    UInt64 totalTokens = cachedGeminiTokens;
    UInt64 totalInputTokens = cachedGeminiInputTokens;
    UInt64 totalOutputTokens = cachedGeminiOutputTokens;
    double totalGeminiCost = cachedGeminiCost;
    NSMutableDictionary *modTimes = [geminiFileModTimes mutableCopy];
    dispatch_semaphore_signal(cacheSemaphore);

    BOOL anyChanges = NO;

    // Traverse <hash>/chats/ directories
    NSArray *hashes = [fm contentsOfDirectoryAtPath:geminiTmpPath error:nil];
    if (!hashes) return;

    for (NSString *hashDir in hashes) {
        NSString *hashPath = [geminiTmpPath stringByAppendingPathComponent:hashDir];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:hashPath isDirectory:&isDir] || !isDir) continue;

        NSString *chatsPath = [hashPath stringByAppendingPathComponent:@"chats"];
        if (![fm fileExistsAtPath:chatsPath isDirectory:&isDir] || !isDir) continue;

        NSArray *files = [fm contentsOfDirectoryAtPath:chatsPath error:nil];
        if (!files) continue;

        for (NSString *filename in files) {
            // Support both .json and .jsonl (modern gemini CLI uses .jsonl)
            if ([filename hasPrefix:@"session-"] && ([filename hasSuffix:@".json"] || [filename hasSuffix:@".jsonl"])) {
                NSString *filePath = [chatsPath stringByAppendingPathComponent:filename];
                
                NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
                if (!attrs) continue;
                
                NSDate *modTime = [attrs fileModificationDate];
                NSDate *oldModTime = modTimes[filePath];
                
                if (oldModTime && [modTime isEqualToDate:oldModTime]) {
                    continue; // Skip unchanged file
                }
                
                anyChanges = YES;
                
                // Subtract old values if they exist
                NSNumber *oldTokens = modTimes[[filePath stringByAppendingString:@"_tokens"]];
                NSNumber *oldInput = modTimes[[filePath stringByAppendingString:@"_input"]];
                NSNumber *oldOutput = modTimes[[filePath stringByAppendingString:@"_output"]];
                NSNumber *oldCost = modTimes[[filePath stringByAppendingString:@"_cost"]];
                
                if (oldTokens) totalTokens -= [oldTokens unsignedLongLongValue];
                if (oldInput) totalInputTokens -= [oldInput unsignedLongLongValue];
                if (oldOutput) totalOutputTokens -= [oldOutput unsignedLongLongValue];
                if (oldCost) totalGeminiCost -= [oldCost doubleValue];
                
                UInt64 fileInput = 0;
                UInt64 fileOutput = 0;
                double fileCost = 0.0;
                
                UInt64 fileTokens = [self parseGeminiSessionFile:filePath inputTokens:&fileInput outputTokens:&fileOutput cost:&fileCost];
                
                totalTokens += fileTokens;
                totalInputTokens += fileInput;
                totalOutputTokens += fileOutput;
                totalGeminiCost += fileCost;
                
                // Update mod times and cached values for this file
                modTimes[filePath] = modTime;
                modTimes[[filePath stringByAppendingString:@"_tokens"]] = @(fileTokens);
                modTimes[[filePath stringByAppendingString:@"_input"]] = @(fileInput);
                modTimes[[filePath stringByAppendingString:@"_output"]] = @(fileOutput);
                modTimes[[filePath stringByAppendingString:@"_cost"]] = @(fileCost);
            }
        }
    }

    // Thread-safe update of cache if any changes detected
    if (anyChanges) {
        dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
        cachedGeminiTokens = totalTokens;
        cachedGeminiInputTokens = totalInputTokens;
        cachedGeminiOutputTokens = totalOutputTokens;
        cachedGeminiCost = totalGeminiCost;
        geminiFileModTimes = modTimes;
        dispatch_semaphore_signal(cacheSemaphore);

#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Gemini cache updated: tokens=%llu (in=%llu out=%llu) cost=$%.4f",
              totalTokens, totalInputTokens, totalOutputTokens, totalGeminiCost);
#endif
    }
}

- (UInt64)parseGeminiSessionFile:(NSString *)filePath inputTokens:(UInt64 *)outInput outputTokens:(UInt64 *)outOutput cost:(double *)outCost {
    UInt64 fileTotal = 0;
    UInt64 fileInput = 0;
    UInt64 fileOutput = 0;
    double fileCost = 0.0;

    if ([filePath hasSuffix:@".jsonl"]) {
        // Handle JSONL format (one JSON object per line)
        FILE *file = fopen([filePath UTF8String], "r");
        if (!file) return 0;

        char *line = NULL;
        size_t linecap = 0;
        ssize_t linelen;

        while ((linelen = getline(&line, &linecap, file)) > 0) {
            if (linelen <= 1) continue;

            @autoreleasepool {
                NSData *jsonData = [NSData dataWithBytesNoCopy:line length:linelen freeWhenDone:NO];
                NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                if (!msg || ![msg isKindOfClass:[NSDictionary class]]) continue;

                NSDictionary *tokens = msg[@"tokens"];
                if (tokens && [tokens isKindOfClass:[NSDictionary class]]) {
                    UInt64 input = [tokens[@"input"] unsignedLongLongValue];
                    UInt64 output = [tokens[@"output"] unsignedLongLongValue];
                    UInt64 total = [tokens[@"total"] unsignedLongLongValue];
                    NSString *modelName = msg[@"model"];
                    
                    if (total == 0) total = input + output;
                    
                    fileInput += input;
                    fileOutput += output;
                    fileTotal += total;
                    
                    // Calculate cost using actual model pricing
                    if (modelName) {
                        XRGModelPricing pricing = getGeminiModelPricing(modelName);
                        fileCost += (input / 1000000.0) * pricing.inputPrice;
                        fileCost += (output / 1000000.0) * pricing.outputPrice;
                    } else {
                        fileCost += (input / 1000000.0) * kGeminiDefaultInputPrice;
                        fileCost += (output / 1000000.0) * kGeminiDefaultOutputPrice;
                    }
                }
            }
        }
        free(line);
        fclose(file);
    } else {
        // Handle legacy single JSON object format
        NSData *jsonData = [NSData dataWithContentsOfFile:filePath];
        if (!jsonData) return 0;

        NSDictionary *data = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if (!data || ![data isKindOfClass:[NSDictionary class]]) return 0;

        NSArray *messages = data[@"messages"];
        NSString *modelName = data[@"model"]; // Try top-level model name
        
        if (messages && [messages isKindOfClass:[NSArray class]]) {
            for (NSDictionary *msg in messages) {
                if (!msg || ![msg isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *tokens = msg[@"tokens"];
                if (tokens && [tokens isKindOfClass:[NSDictionary class]]) {
                    UInt64 input = [tokens[@"input"] unsignedLongLongValue];
                    UInt64 output = [tokens[@"output"] unsignedLongLongValue];
                    UInt64 total = [tokens[@"total"] unsignedLongLongValue];
                    
                    if (total == 0) total = input + output;
                    
                    fileInput += input;
                    fileOutput += output;
                    fileTotal += total;
                    
                    // Calculate cost
                    if (modelName) {
                        XRGModelPricing pricing = getGeminiModelPricing(modelName);
                        fileCost += (input / 1000000.0) * pricing.inputPrice;
                        fileCost += (output / 1000000.0) * pricing.outputPrice;
                    } else {
                        fileCost += (input / 1000000.0) * kGeminiDefaultInputPrice;
                        fileCost += (output / 1000000.0) * kGeminiDefaultOutputPrice;
                    }
                }
            }
        }
    }

    if (outInput) *outInput = fileInput;
    if (outOutput) *outOutput = fileOutput;
    if (outCost) *outCost = fileCost;

    return fileTotal;
}

// Backward compatibility wrappers
- (UInt64)parseGeminiSessionFile:(NSString *)filePath inputTokens:(UInt64 *)outInput outputTokens:(UInt64 *)outOutput {
    return [self parseGeminiSessionFile:filePath inputTokens:outInput outputTokens:outOutput cost:NULL];
}

- (UInt64)parseGeminiSessionFile:(NSString *)filePath {
    return [self parseGeminiSessionFile:filePath inputTokens:NULL outputTokens:NULL cost:NULL];
}

#pragma mark - Accessor Methods

- (UInt32)claudeTokenRate {
    return currentClaudeRate;
}

- (UInt32)codexTokenRate {
    return currentCodexRate;
}

- (UInt32)geminiTokenRate {
    return currentGeminiRate;
}

- (UInt32)ollamaTokenRate {
    return currentOllamaRate;
}

- (UInt32)hermesTokenRate {
    return currentHermesRate;
}

- (UInt32)totalTokenRate {
    return currentClaudeRate + currentCodexRate + currentGeminiRate + currentOllamaRate + currentHermesRate;
}

- (XRGDataSet *)claudeTokenData {
    return claudeCodeTokens;
}

- (XRGDataSet *)codexTokenData {
    return codexTokens;
}

- (XRGDataSet *)geminiTokenData {
    return geminiTokens;
}

- (XRGDataSet *)ollamaTokenData {
    return ollamaTokens;
}

- (XRGDataSet *)hermesTokenData {
    return hermesTokens;
}

- (double)hermesCostUSD {
    return hermesCostUSD;
}

- (NSDictionary *)hermesModelTokens {
    return [hermesModelTokens copy];
}

- (NSString *)hermesTopModel {
    return hermesTopModel;
}

- (XRGDataSet *)costData {
    return costPerSecond;
}

#pragma mark - Cost Intelligence Methods

- (void)calculateCosts {
    // Calculate costs using DYNAMIC PER-MODEL PRICING
    // Claude: Use per-model cost calculated during JSONL parsing (accurate)
    // Codex/Gemini: Use default pricing with estimation (model name parsing TODO)

    double claudeCost = 0.0;
    double codexCost = 0.0;
    double geminiCost = 0.0;

    // CLAUDE: Use per-model calculated cost if available (from JSONL parsing)
    NSNumber *perModelCost = claudeModelCosts[@"_total"];
    if (perModelCost && [perModelCost doubleValue] > 0) {
        // We have accurate per-model costs calculated during file parsing
        claudeCost = [perModelCost doubleValue];
    } else if (claudeInputTokens > 0 || claudeOutputTokens > 0) {
        // Fallback: Use default Sonnet pricing with actual input/output counts
        claudeCost = (claudeInputTokens / 1000000.0) * kClaudeDefaultInputPrice +
                     (claudeOutputTokens / 1000000.0) * kClaudeDefaultOutputPrice;
    } else if (_totalClaudeTokens > 0) {
        // Last resort: Estimate with 70/30 split and default pricing
        UInt64 estimatedInput = (UInt64)(_totalClaudeTokens * 0.70);
        UInt64 estimatedOutput = _totalClaudeTokens - estimatedInput;
        claudeCost = (estimatedInput / 1000000.0) * kClaudeDefaultInputPrice +
                     (estimatedOutput / 1000000.0) * kClaudeDefaultOutputPrice;
    }

    // CODEX: Use default pricing (model name parsing in Codex JSONL TODO)
    if (codexInputTokens > 0 || codexOutputTokens > 0) {
        codexCost = (codexInputTokens / 1000000.0) * kCodexDefaultInputPrice +
                    (codexOutputTokens / 1000000.0) * kCodexDefaultOutputPrice;
    } else if (_totalCodexTokens > 0) {
        UInt64 estimatedInput = (UInt64)(_totalCodexTokens * 0.70);
        UInt64 estimatedOutput = _totalCodexTokens - estimatedInput;
        codexCost = (estimatedInput / 1000000.0) * kCodexDefaultInputPrice +
                    (estimatedOutput / 1000000.0) * kCodexDefaultOutputPrice;
    }

    // GEMINI: Use accurate cached cost if available, otherwise estimate
    if (cachedGeminiCost > 0.0) {
        geminiCost = cachedGeminiCost;
    } else if (geminiInputTokens > 0 || geminiOutputTokens > 0) {
        geminiCost = (geminiInputTokens / 1000000.0) * kGeminiDefaultInputPrice +
                     (geminiOutputTokens / 1000000.0) * kGeminiDefaultOutputPrice;
    } else if (_totalGeminiTokens > 0) {
        UInt64 estimatedInput = (UInt64)(_totalGeminiTokens * 0.70);
        UInt64 estimatedOutput = _totalGeminiTokens - estimatedInput;
        geminiCost = (estimatedInput / 1000000.0) * kGeminiDefaultInputPrice +
                     (estimatedOutput / 1000000.0) * kGeminiDefaultOutputPrice;
    }

    // HERMES: cost comes straight from its own DB (actual/estimated_cost_usd),
    // already aggregated in fetchFromHermesDatabase. Do not re-price it.
    _totalCostUSD = claudeCost + codexCost + geminiCost + hermesCostUSD;
}

- (double)costPerHour {
    // Calculate $/hour based on current rate ($/second)
    // currentCostRate is $/second, so multiply by 3600
    return currentCostRate * 3600.0;
}

- (double)projectedDailyCost {
    // Project 24-hour cost at current burn rate
    return [self costPerHour] * 24.0;
}

- (double)claudeCostUSD {
    // PRIORITY: Use per-model calculated cost (most accurate)
    NSNumber *perModelCost = claudeModelCosts[@"_total"];
    if (perModelCost && [perModelCost doubleValue] > 0) {
        return [perModelCost doubleValue];
    }

    // Fallback: Use default pricing with token counts
    if (claudeInputTokens > 0 || claudeOutputTokens > 0) {
        return (claudeInputTokens / 1000000.0) * kClaudeDefaultInputPrice +
               (claudeOutputTokens / 1000000.0) * kClaudeDefaultOutputPrice;
    } else if (_totalClaudeTokens > 0) {
        UInt64 estimatedInput = (UInt64)(_totalClaudeTokens * 0.70);
        UInt64 estimatedOutput = _totalClaudeTokens - estimatedInput;
        return (estimatedInput / 1000000.0) * kClaudeDefaultInputPrice +
               (estimatedOutput / 1000000.0) * kClaudeDefaultOutputPrice;
    }
    return 0.0;
}

- (double)codexCostUSD {
    if (codexInputTokens > 0 || codexOutputTokens > 0) {
        return (codexInputTokens / 1000000.0) * kCodexDefaultInputPrice +
               (codexOutputTokens / 1000000.0) * kCodexDefaultOutputPrice;
    } else if (_totalCodexTokens > 0) {
        UInt64 estimatedInput = (UInt64)(_totalCodexTokens * 0.70);
        UInt64 estimatedOutput = _totalCodexTokens - estimatedInput;
        return (estimatedInput / 1000000.0) * kCodexDefaultInputPrice +
               (estimatedOutput / 1000000.0) * kCodexDefaultOutputPrice;
    }
    return 0.0;
}

- (double)geminiCostUSD {
    if (cachedGeminiCost > 0.0) {
        return cachedGeminiCost;
    }
    
    if (geminiInputTokens > 0 || geminiOutputTokens > 0) {
        return (geminiInputTokens / 1000000.0) * kGeminiDefaultInputPrice +
               (geminiOutputTokens / 1000000.0) * kGeminiDefaultOutputPrice;
    } else if (_totalGeminiTokens > 0) {
        UInt64 estimatedInput = (UInt64)(_totalGeminiTokens * 0.70);
        UInt64 estimatedOutput = _totalGeminiTokens - estimatedInput;
        return (estimatedInput / 1000000.0) * kGeminiDefaultInputPrice +
               (estimatedOutput / 1000000.0) * kGeminiDefaultOutputPrice;
    }
    return 0.0;
}

#pragma mark - Private Networking Helper

- (NSData *)xrg_syncDataForRequest:(NSURLRequest *)request returningResponse:(NSHTTPURLResponse * _Nullable __autoreleasing *)response error:(NSError * _Nullable __autoreleasing *)error {
    __block NSData *resultData = nil;
    __block NSURLResponse *resultResponse = nil;
    __block NSError *resultError = nil;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.requestCachePolicy = request.cachePolicy;
    config.timeoutIntervalForRequest = request.timeoutInterval > 0 ? request.timeoutInterval : 2.0;
    config.timeoutIntervalForResource = config.timeoutIntervalForRequest + 1.0;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
        resultData = data;
        resultResponse = resp;
        resultError = err;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    // Wait up to the timeout + small grace period
    NSTimeInterval waitSeconds = config.timeoutIntervalForRequest + 0.5;
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitSeconds * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sema, timeout) != 0) {
        // Timed out
        [task cancel];
        resultError = resultError ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    }

    [session finishTasksAndInvalidate];

    if (response) {
        if ([resultResponse isKindOfClass:[NSHTTPURLResponse class]]) {
            *response = (NSHTTPURLResponse *)resultResponse;
        } else {
            *response = nil;
        }
    }
    if (error) {
        *error = resultError;
    }
    return resultData;
}

#pragma mark - Ollama Local Inference Methods

- (BOOL)fetchFromOllamaAPI {
    // CRITICAL: Return immediately with cached value (non-blocking!)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    _totalOllamaTokens = cachedOllamaTokens;
    dispatch_semaphore_signal(cacheSemaphore);

    // Check if we should trigger background update (throttled)
    NSDate *now = [NSDate date];
    BOOL shouldUpdate = NO;

    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    // Throttle to every 5 seconds for Ollama API (it's a network call)
    if (!lastOllamaScanTime || [now timeIntervalSinceDate:lastOllamaScanTime] > 5.0) {
        shouldUpdate = YES;
        lastOllamaScanTime = now;
    }
    dispatch_semaphore_signal(cacheSemaphore);

    // Dispatch background update (non-blocking)
    if (shouldUpdate) {
        dispatch_async(jsonlParsingQueue, ^{
            [self updateOllamaStatusInBackground];
        });
    }

    return _ollamaAvailable;
}

- (void)updateOllamaStatusInBackground {
    // Check Ollama availability via /api/tags
    NSURL *tagsUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/tags", ollamaApiEndpoint]];
    if (!tagsUrl) {
        dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
        _ollamaAvailable = NO;
        dispatch_semaphore_signal(cacheSemaphore);
        return;
    }

    NSURLRequest *tagsRequest = [NSURLRequest requestWithURL:tagsUrl
                                                 cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                             timeoutInterval:2.0];

    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *tagsData = [self xrg_syncDataForRequest:tagsRequest returningResponse:&response error:&error];

    if (error || !tagsData || response.statusCode != 200) {
        // Ollama not available
        dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
        _ollamaAvailable = NO;
        ollamaAvailableModels = @[];
        _ollamaRunningModels = @[];
        dispatch_semaphore_signal(cacheSemaphore);
#ifdef XRG_DEBUG
        NSLog(@"[XRGAITokenMiner] Ollama not available: %@", error ? error.localizedDescription : @"HTTP error");
#endif
        return;
    }

    // Parse available models
    NSDictionary *tagsJson = [NSJSONSerialization JSONObjectWithData:tagsData options:0 error:nil];
    NSArray *models = tagsJson[@"models"];
    NSMutableArray *modelNames = [NSMutableArray array];
    if (models && [models isKindOfClass:[NSArray class]]) {
        for (NSDictionary *model in models) {
            NSString *name = model[@"name"];
            if (name) [modelNames addObject:name];
        }
    }

    // Now check running models via /api/ps
    NSURL *psUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/ps", ollamaApiEndpoint]];
    NSURLRequest *psRequest = [NSURLRequest requestWithURL:psUrl
                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                           timeoutInterval:2.0];

    NSData *psData = [self xrg_syncDataForRequest:psRequest returningResponse:&response error:&error];

    NSMutableArray *runningNames = [NSMutableArray array];
    if (!error && psData && response.statusCode == 200) {
        NSDictionary *psJson = [NSJSONSerialization JSONObjectWithData:psData options:0 error:nil];
        NSArray *runningModels = psJson[@"models"];
        if (runningModels && [runningModels isKindOfClass:[NSArray class]]) {
            for (NSDictionary *model in runningModels) {
                NSString *name = model[@"name"];
                if (name) [runningNames addObject:name];
            }
        }
    }

    // Update state (thread-safe)
    dispatch_semaphore_wait(cacheSemaphore, DISPATCH_TIME_FOREVER);
    _ollamaAvailable = YES;
    ollamaAvailableModels = [modelNames copy];
    _ollamaRunningModels = [runningNames copy];
    dispatch_semaphore_signal(cacheSemaphore);

#ifdef XRG_DEBUG
    NSLog(@"[XRGAITokenMiner] Ollama: %lu models available, %lu running",
          (unsigned long)modelNames.count, (unsigned long)runningNames.count);
#endif
}

- (NSString *)ollamaStatusString {
    if (!_ollamaAvailable) {
        return @"Ollama: Not running";
    }

    NSUInteger availableCount = ollamaAvailableModels.count;
    NSUInteger runningCount = _ollamaRunningModels.count;

    if (runningCount > 0) {
        // Show first running model name
        NSString *firstModel = _ollamaRunningModels[0];
        // Shorten model name if too long
        if (firstModel.length > 15) {
            firstModel = [[firstModel substringToIndex:12] stringByAppendingString:@"..."];
        }
        if (runningCount == 1) {
            return [NSString stringWithFormat:@"Ollama: %@ (%lu avail)",
                    firstModel, (unsigned long)availableCount];
        } else {
            return [NSString stringWithFormat:@"Ollama: %@ +%lu (%lu avail)",
                    firstModel, (unsigned long)(runningCount - 1), (unsigned long)availableCount];
        }
    } else {
        return [NSString stringWithFormat:@"Ollama: Ready (%lu models)", (unsigned long)availableCount];
    }
}

@end

