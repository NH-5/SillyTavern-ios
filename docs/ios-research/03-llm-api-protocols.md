# SillyTavern 直连 LLM 供应商 API 协议规范（Swift / URLSession 重写依据）

> 调研对象：`/Users/wuzheng/projects/SillyTavern-ios`（SillyTavern，分支 `dsh`）。
> 所有结论均标注 `文件:行号`。行号对应当前工作区快照，重构后可能漂移。
> 阅读方式：服务端为 `src/endpoints/backends/chat-completions.js`（chat 类）与
> `src/endpoints/backends/text-completions.js` + `kobold.js`（text 类）；
> 客户端（浏览器侧）负责最终 SSE 解析：`public/scripts/sse-stream.js` 与 `public/scripts/openai.js`。

---

## 0. 架构结论（决定 Swift 侧的分层）

SillyTavern 有**两层**，重写时必须区分：

1. **服务端中转层**（Node）：浏览器 POST `/api/backends/chat-completions/generate`，
   服务端把 `generate_data` 翻译成各供应商的 HTTP 请求，并把**上游响应原样 pipe 回浏览器**
   （`src/endpoints/backends/chat-completions.js:2689-2694`、`src/util.js:732-779`）。
   服务端**不做 SSE 解析**，只在非流式时把上游 JSON 透传（`:2696-2700`）。
2. **客户端解析层**（浏览器 JS）：`EventSourceStream` 做 SSE 分帧
   （`public/scripts/sse-stream.js:10-81`），`getStreamingReply()` 做各供应商的增量文本提取
   （`public/scripts/openai.js:3222-3306`）。

**Swift 重写的正确形态**：把两层合并 —— 直接对上游发请求，然后在客户端做 SSE 分帧 + 增量提取。
因此本规范同时给出「上游真实协议」与「ST 的提取规则」，后者是必须逐字复刻的部分。

### 0.1 ST 客户端的 `generate_data`（浏览器 → ST 服务端的中间格式）

不是上游协议，但决定了哪些字段最终会被发出去，字段清单见
`public/scripts/openai.js:2803-2828`（基础）+ `:2830-3124`（按供应商增删）。

```jsonc
{
  "type": "normal",                  // normal | quiet | impersonate | continue
  "messages": [ { "role": "system", "content": "..." } ],
  "model": "gpt-5.6-terra",
  "temperature": 1.0,
  "frequency_penalty": 0,
  "presence_penalty": 0,
  "top_p": 1.0,
  "max_tokens": 300,
  "stream": false,
  "logit_bias": { "1234": -100 },
  "stop": ["\nUser:"],
  "chat_completion_source": "openai",
  "n": 1,
  "include_reasoning": true,
  "reasoning_effort": "auto",
  "enable_web_search": false,
  "request_images": false,
  "custom_prompt_post_processing": null,
  "verbosity": "auto",
  "seed": -1,                        // 只有 seedSupportedSources 且 >=0 才保留（:3046-3048）
  "reverse_proxy": "",
  "proxy_password": ""
}
```
（`public/scripts/openai.js:2803-2828`）

---

## 1. OpenAI 兼容路径（最重要）

### 1.1 请求 URL 与 base URL 拼接规则

服务端常量：`src/endpoints/backends/chat-completions.js:73`

```js
const API_OPENAI = 'https://api.openai.com/v1';
```

URL 解析与端点拼接（`chat-completions.js:2281-2284`、`:2625-2628`）：

```js
apiUrl = new URL(request.body.reverse_proxy || API_OPENAI).toString();
...
const endpointUrl = isTextCompletion && source !== OPENROUTER
    ? `${apiUrl}/completions`
    : `${apiUrl}/chat/completions`;
```

**精确规则（已用 Node 实测验证）：**

| 用户输入 base URL | `new URL(x).toString()` | 最终 URL |
|---|---|---|
| `https://api.openai.com/v1` | `https://api.openai.com/v1` | `https://api.openai.com/v1/chat/completions` |
| `https://api.openai.com/v1/` | `https://api.openai.com/v1/` | `https://api.openai.com/v1//chat/completions` ⚠️ 双斜杠 |
| `http://localhost:1234/v1` | `http://localhost:1234/v1` | `http://localhost:1234/v1/chat/completions` |
| `https://my.proxy.example.com/` | `https://my.proxy.example.com/` | `https://my.proxy.example.com//chat/completions` ⚠️ |

- **不存在自动补 `/v1`**：`new URL()` 只做 URL 规范化，不做路径补全。
  UI 占位符明确提示用户带上 `/v1`：`public/scripts/openai.js:5755`
  （`$('#openai_reverse_proxy').attr('placeholder', 'https://api.openai.com/v1')`，
  Claude 为 `https://api.anthropic.com/v1`，`:5744`）。
- **只 trim 一次尾斜杠**的辅助函数 `trimTrailingSlash` 存在（`src/util.js:910-912`），
  但在整个 chat-completions.js 中**只用于 Gemini 的 `/status` 探测**（`:1910`），
  `/generate` 路径完全依赖 `new URL()`。
- 唯一对 base 做 `replace(/\/$/, '')` 的是 Gemini（`chat-completions.js:726`、`:730`）。
- `CUSTOM` 源**完全不做任何规范化**：`apiUrl = request.body.custom_url`（`:2395`），
  直接字符串拼 `${apiUrl}/chat/completions`。UI 侧只校验 `isValidUrl`（`public/scripts/openai.js:4475-4479`，
  实现 `public/scripts/utils.js:173-180`）。
- 文本补全（textgen）路径用的是 `trimV1`：`src/util.js:901-903`
  `String(str).replace(/\/$/,'').replace(/\/v1$/,'')`，即**先去掉 `/v1` 再自己拼回**
  （`src/endpoints/backends/text-completions.js:294`、`:307`）。

`/status` 探测用 `${base}/models`：`urlJoin(apiUrl, '/models')`
（`src/endpoints/backends/chat-completions.js:2072`）。

**Swift 建议**：实现与 `new URL()` 等价的 `URL(string:)` 后取 `absoluteString`；
对 `CUSTOM` 保持原样拼接以对齐 ST 行为（含双斜杠容忍）。

### 1.2 认证头与自定义头

基础配置（`chat-completions.js:2675-2685`）：

```js
const config = {
    method: 'post',
    headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey,
        ...headers,
    },
    body: JSON.stringify(requestBody),
    signal: controller.signal,
};
```

- `apiKey` 来源：`reverse_proxy` 存在时用 `request.body.proxy_password`，否则 `readSecret(...)`
  （`:2283`）。`readSecret` 在无密钥时返回**空字符串**（`src/endpoints/secrets.js:268-282`），
  因此关闭鉴权的自建服务会收到 `Authorization: Bearer `（尾部一个空格）。
- **额外 header 是支持的，但只有 `CUSTOM` 源可任意指定**：
  `mergeObjectWithYaml(headers, request.body.custom_include_headers)`（`:2410`），
  YAML 解析后 `Object.assign` 进 headers（`src/util.js:844-864`）。
- 各供应商内置额外头：
  - OpenRouter：`{'HTTP-Referer': 'https://sillytavern.app', 'X-Title': 'SillyTavern'}`
    （`src/constants.js:362-365`，使用处 `chat-completions.js:2305`）。
  - AI/ML API：同上两个头（`src/constants.js:367-370`，使用处 `:1356`）。
  - Fireworks：`x-session-affinity` = `HMAC-SHA256(cookieSecret, chat_id)` 前 16 个 hex 字符
    （`:2473-2475`）。
  - nano-gpt：`X-Provider`（`:2482`）、`X-Billing-Mode: paygo`（`:2485`）。
  - Z.AI：`Accept-Language: en-US,en`（`:2555-2557`）。
  - Azure：`api-key`（**不是** Bearer，`:1743`）。
  - Claude：`x-api-key` + `anthropic-version` + `anthropic-beta`（`:414-419`）。
- 另有服务端 `requestOverrides` 配置可为指定 host 注入 header
  （`src/additional-headers.js:getOverrideHeaders`，仅 textgen / kobold 路径使用）。
- **鉴权形式**：上游统一 `Authorization: Bearer`（Azure/Claude 例外）。
  ST 自己的 CSRF（`x-csrf-token`，`src/server-main.js:168-205`）是 ST 服务端的会话鉴权，
  与直连上游无关，iOS 直连不需要。

### 1.3 请求体完整字段清单

服务端最终组装的 `requestBody`（`chat-completions.js:2652-2669`）：

```js
const requestBody = {
    'messages': isTextCompletion === false ? request.body.messages : undefined,
    'prompt':   isTextCompletion === true  ? textPrompt : undefined,
    'model':    request.body.model,
    'temperature': request.body.temperature,
    'max_tokens':  request.body.max_tokens,
    'max_completion_tokens': request.body.max_completion_tokens,
    'stream':   request.body.stream,
    'presence_penalty':  request.body.presence_penalty,
    'frequency_penalty': request.body.frequency_penalty,
    'top_p':    request.body.top_p,
    'top_k':    request.body.top_k,
    'stop':     isTextCompletion === false ? request.body.stop : undefined,
    'logit_bias': request.body.logit_bias,
    'seed':     request.body.seed,
    'n':        request.body.n,
    ...bodyParams,          // 供应商特有字段，见下
};
```

**关键点：值为 `undefined` 的键会被 `JSON.stringify` 丢弃**，所以「总是发送」的其实只有
`messages`/`prompt`、`model`、`stream` 和少数非空的采样参数。

`bodyParams`（`OPENAI` 源，`:2285-2300`）：

| 字段 | 条件 | 说明 |
|---|---|---|
| `logprobs` | `logprobs > 0` 时改为布尔 `true` | 客户端只在开启「请求 token 概率」时传 `5`（`public/scripts/openai.js:2856-2859`） |
| `top_logprobs` | `logprobs > 0` 时 = 原数值 | Chat Completions 规范要求 `{logprobs: bool, top_logprobs: int}`（`:2290-2294`） |
| `user` | 仅当配置 `openai.randomizeUserId` 为真 | 值 = `uuidv4()`（`:2296-2298`） |
| `reasoning_effort` | `request.body.reasoning_effort` 存在且 model 在 `OPENAI_REASONING_EFFORT_MODELS` | 会经 `OPENAI_FIXED_REASONING_EFFORT` / `OPENAI_REASONING_EFFORT_MAP` 映射（`:2600-2603`，表见 `src/constants.js:461-515`） |
| `verbosity` | `request.body.verbosity` 存在且 model 匹配 `/^(?:gpt-5|gpt-6-astra)/` | `src/constants.js:459`；使用处 `:2609-2613` |
| `tools` / `tool_choice` | `!isTextCompletion && Array.isArray(tools) && tools.length > 0` | `:2636-2639` |
| `response_format` | `request.body.json_schema` 存在且尚未设置 | `{type:'json_schema', json_schema:{name, strict:true, schema}}`（`:2641-2650`） |
| `stop` | `Array.isArray(stop) && stop.length > 0` | 覆盖式写入（`:2620-2623`） |
| `stream_options` | **从不发送** | 全仓库 grep 无任何使用 |

**客户端侧对请求体的进一步删改**（`public/scripts/openai.js:3046-3120`）——这些决定「哪些参数在什么模型下**不能**出现」：

- `seed`：仅 `seedSupportedSources` 且 `settings.seed >= 0` 时保留（`:2720-2736`、`:3046-3048`）。
- `o1/o3/o4`（OPENAI/AZURE/OPENROUTER）：`max_tokens` → `max_completion_tokens`，
  并删除 `logprobs/top_logprobs/stop/logit_bias/temperature/top_p/frequency_penalty/presence_penalty`；
  `o1` 还要把 `system` role 改成 `user`、删 `n`/`tools`/`tool_choice`（`:3050-3072`）。
- `gpt-5*`：`max_tokens` → `max_completion_tokens`，删 `logprobs/top_logprobs`；
  非 chat-latest 分支再删采样参数与 `stop`/`logit_bias`（`:3074-3095`）。
- `gpt-6-astra`：`max_completion_tokens`，删 `temperature/top_p/logprobs`（`:3097-3104`）。
- 视觉模型（model 含 `gpt` 和 `vision`）：删 `logit_bias/stop/logprobs`（`:2862-2867`）。
- `claude-(fable|opus-5|sonnet-5)`：删所有采样参数（`:3109-3120`）。
- Groq：删 `logprobs/logit_bias/top_logprobs/n`（`:2947-2952`）。
- DeepSeek：`top_p = top_p || Number.EPSILON`（不能为 0，`:2955-2957`）。
- Z.AI：`top_p = top_p || 0.01`，删 `presence_penalty/frequency_penalty`（`:2993-2999`）。
- MiniMax：`temperature` 夹到 `(0, 1]`（`:3011-3014`），`M2-her` 的 `max_tokens` 夹到 2048（`chat-completions.js:1639`）。
- Workers AI：`top_p >= 0.001`，`top_k <= 50`（`:3017-3025`）。

### 1.4 最小请求体 JSON 示例（OpenAI 兼容）

```json
{
  "messages": [
    { "role": "system", "content": "You are a helpful assistant." },
    { "role": "user", "content": "Hello!" }
  ],
  "model": "gpt-4o-mini",
  "temperature": 1.0,
  "frequency_penalty": 0,
  "presence_penalty": 0,
  "top_p": 1.0,
  "max_tokens": 300,
  "stream": true,
  "stop": ["\nUser:"],
  "seed": 42,
  "n": 1
}
```

HTTP 层面：

```http
POST /v1/chat/completions HTTP/1.1
Host: api.openai.com
Content-Type: application/json
Authorization: Bearer sk-...
Accept: */*
```

> 无 `Accept-Encoding` 特判；`node-fetch` 默认发送 `accept: */*` 与 gzip。
> iOS 用 `URLSession` 时保持默认即可，但**必须**设置 `Accept: text/event-stream`
> 或至少不要做响应缓冲（见 §1.6 状态机）。

### 1.5 流式响应（SSE）

#### 1.5.1 上游线格式

标准 SSE：事件之间以空行分隔，每个事件由若干 `字段: 值` 行组成，结束标记为字面量：

```
data: [DONE]
```

ST 的 SSE 分帧实现（`public/scripts/sse-stream.js:17-67`）：

```js
// 事件分隔：两个换行（兼容 \r\n\r\n / \r\r / \n\n）
const events = streamBuffer.split(/\r\n\r\n|\r\r|\n\n/g);
streamBuffer = events.pop();               // 剩下的不完整片段留在 buffer
...
const lines = eventChunk.split(/\n|\r|\r\n/g);
const lineMatch = /([^:]+)(?:: ?(.*))?/.exec(line);
// field: event | data | id ；忽略 delay 与其他
// data 字段：多个 data 行用 '\n' 拼接
if (eventData === '') continue;            // 空 data 事件跳过
if (eventData.endsWith('\n')) eventData = eventData.slice(0, -1);   // 只裁掉最后一个换行
const event = new MessageEvent(eventType || 'message', { data: eventData, lastEventId });
```

消费侧（`public/scripts/openai.js:3160-3189`）：

```js
const eventStream = getEventSourceStream();
response.body.pipeThrough(eventStream);
const reader = eventStream.readable.getReader();
...
const rawData = value.data;
if (rawData === '[DONE]') return;          // 流结束
tryParseStreamingError(response, rawData);
const parsed = JSON.parse(rawData);
if (canMultiSwipe && parsed?.choices?.[0]?.index > 0) { /* 多 swipe，index-1 */ }
else { text += getStreamingReply(parsed, state); }
ToolManager.parseToolCalls(toolCalls, parsed, state.toolSignatures);
```

**必须复刻的细节**：
1. `[DONE]` 是**字面字符串比较**，只对 OpenAI 系有效；Anthropic/Gemini 靠连接关闭结束（§2/§3）。
2. 每个 `data:` 载荷单独 `JSON.parse`；解析失败要走错误探测而不是崩。
3. `choices[0].index > 0` 表示这是第 n 个候选（`n>1` 多 swipe），文本要单独累积
   （`openai.js:3177-3180`）。
4. `choices` 为空数组按异常处理（`sse-stream.js:215-217`）。

#### 1.5.2 流式响应分块示例（OpenAI 兼容）

```
data: {"id":"chatcmpl-9x","object":"chat.completion.chunk","created":1712345678,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-9x","object":"chat.completion.chunk","created":1712345678,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-9x","object":"chat.completion.chunk","created":1712345678,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-9x","object":"chat.completion.chunk","created":1712345678,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]

```

#### 1.5.3 `delta` 内容提取规则（`getStreamingReply`，`public/scripts/openai.js:3222-3306`）

按 `chat_completion_source` 分支，OpenAI 系（含 `CUSTOM/POLLINATIONS/AIMLAPI/MOONSHOT/COMETAPI/
ELECTRONHUB/NANOGPT/ZAI/SILICONFLOW/CHUTES/WORKERS_AI/FIREWORKS`）走 `:3289-3296`：

```js
// 思维链（仅当 show_thoughts 打开）
state.reasoning +=
    data.choices?.filter(x => x?.delta?.reasoning_content)?.[0]?.delta?.reasoning_content ??
    data.choices?.filter(x => x?.delta?.reasoning)?.[0]?.delta?.reasoning ??
    '';
// 正文（注意 ?? 链：null/undefined 才继续，空字符串 '' 会立即短路返回）
return data.choices?.[0]?.delta?.content
    ?? data.choices?.[0]?.message?.content
    ?? data.choices?.[0]?.text
    ?? '';
```

OPENROUTER 分支（`:3259-3288`）顺序是 `delta.reasoning` → `delta.reasoning_content` →
`message.reasoning` → `message.reasoning_content`，正文 `delta.content ?? message.content ?? text`。

未匹配任何 source 的兜底分支（`:3303-3305`）与 OpenAI 系正文规则相同。

**要点**：
- `delta.role`（首个 chunk 的 `"role":"assistant"`）**被忽略**，不产生文本。
- **空 delta `{}`**：`?.content` 为 `undefined`，`??` 链最终返回 `''`，安全。
- `reasoning_content` / `reasoning` 只在 `show_thoughts` 为真时累积到 `state.reasoning`
  （`:3224`、`:3290`），**不进入正文**。`show_thoughts` 来自 `oai_settings.show_thoughts`，
  默认 `true`（`public/scripts/openai.js:507`）。
- OpenAI 原生**不返回** `reasoning_content`；该字段由 DeepSeek/xAI/OpenRouter/自建服务返回。
  DeepSeek 分支 `:3249-3253`、xAI 分支 `:3254-3258` 与此等价但少一层 `??`。
- Mistral 特殊：`delta.content` 可以是**数组**。ST 读取的思维链路径是
  `delta.content[0].thinking[0].text`（`:3299`），正文则是
  `content.map(x => x.text).filter(Boolean).join('')`（`:3301-3302`）——
  即数组元素为带 `text` 字段的对象（如 `{type:'text', text:'...'}`）。
  文本提取必须先判断 `content` 是字符串还是数组。

**平滑流式（可选特性，Swift 可省略）**：`SmoothEventSourceStream`
（`sse-stream.js:340-379`）用 `parseStreamData()`（`:113-335`）把每个 chunk **按字符拆成多个事件**，
用于打字机效果。其优先级顺序即「一个 chunk 里该先读哪个字段」的权威列表：

1. Cohere：`delta.message.content.text`（`type` ∈ `tool-plan-delta`/`content-delta`）
2. Claude：`delta.text`
3. Claude thinking：`delta.thinking`（标记 `reasoning: true`）
4. Gemini：`candidates[i].content.parts[j].text`（`part.thought` 为真 ⇒ reasoning）
5. NovelAI/KoboldCpp Classic：`token`
6. llama.cpp：`content`（且 `object !== 'chat.completion.chunk'`）
7. OpenAI 系：`choices[0].text` → `choices[0].thinking` → `choices[0].delta.text`
   → `delta.reasoning_content` → `delta.reasoning` → `delta.content`(string)
   → `delta.content[0].thinking[0].text` → `choices[0].message.content`
8. 都不匹配 ⇒ 抛 `Unknown event data format`（被捕获后原样放行，不致命）

#### 1.5.4 tool_calls 增量

`ToolManager.parseToolCalls`（`public/scripts/tool-calling.js:427-471`）：
按 `choice.index` 分桶，再按 `delta.tool_calls[k].index` 累积，`#applyToolCallDelta` 合并
`id`/`function.name`/`function.arguments` 的字符串增量。Cohere 走 `type` 事件
（`message-start`/`tool-call-start`/`tool-call-delta`/`tool-call-end`，`:472-487`），
Claude 走 `content_block.type === 'tool_use'`（`:488-499`）。

#### 1.5.5 错误响应与 HTTP 状态处理

**非流式**（`chat-completions.js:2696-2716`）：

```js
if (fetchResponse.ok) { return response.send(await fetchResponse.json()); }
else {
    const responseText = await fetchResponse.text();
    const errorData = tryParse(responseText);
    const message = fetchResponse.statusText || 'Unknown error occurred';
    const quota_error = fetchResponse.status === 429 && errorData?.error?.type === 'insufficient_quota';
    response.send({ error: { message }, quota_error });   // ⚠️ HTTP 200，只用 body.error 表达失败
}
```

- **上游正文被丢弃**，只把 `statusText` 当消息（如 `"Bad Request"`）。
- 网络层异常 → HTTP **502** + `{error: {message, ...error}}`，`ECONNREFUSED` 前缀
  `Connection refused: `（`:2717-2728`）。

**流式**（`src/util.js:732-779` `forwardFetchResponse`）：

- 上游 `!ok` ⇒ 把上游 HTTP 状态原样写回（**但 401 被改写成 400**，`:741-743`），
  并把上游错误正文 `to.end(rawErrorText)` 原样作为响应体。
- 上游 `ok` ⇒ `from.body.pipe(to)`，socket close 时销毁上游流。

**客户端错误识别**（`public/scripts/openai.js:1635-1679`）：

```js
function getChatCompletionErrorMessage(data, response) {
    const error = data?.error ?? data?.detail?.error;
    const message = typeof error === 'string' ? error : (error?.message || error?.code || error?.type);
    return String(message || (!response.ok && response.statusText) || 'Unknown error');
}
// tryParseStreamingError：JSON.parse(decoded) 后依次检查
//   data.quota_error            → 配额弹窗（:1689-1701）
//   data.error.message 含 'requires moderation' → 展示 reasons/flagged_input（:1708-1715）
//   data.error / data.message / data.detail  → toastr 报错
```

**Swift 侧应实现的错误模型**（兼容上游各家）：

```
{ "error": { "message": "...", "type": "...", "code": "...", "param": "...", "metadata": {...} } }
{ "detail": { "error": {...} } }        // 某些代理
{ "message": "..." }                    // Gemini 风格
```

判定顺序：HTTP 非 2xx → 解析 body 取上述任一 message；若 body 非 JSON，用
`HTTPURLResponse.localizedString(forStatusCode:)` 兜底（等价 ST 的 `statusText`）。
`429 + error.type == "insufficient_quota"` 要单独识别为配额错误。

### 1.6 Swift SSE 解析状态机

```swift
enum SSEFrame { case data(String), done }

// 输入：URLSession.bytes(for:) 的字节流（AsyncBytes）
// 状态：buffer（跨 chunk 保留的不完整文本）
func feed(_ chunk: String, into buffer: inout String) -> [SSEFrame] {
    buffer += chunk
    // 1) 事件分隔：\r\n\r\n | \r\r | \n\n（正则 /\r\n\r\n|\r\r|\n\n/）
    // 2) 最后一段（无终止空行）留在 buffer
    // 3) 每个事件内按 /\n|\r|\r\n/ 拆行，正则 /([^:]+)(?:: ?(.*))?/ 解析
    //    - "data"  -> eventData += value + "\n"
    //    - "event" -> 记录类型（OpenAI 无此字段；Anthropic 有，见 §2）
    //    - "id"    -> 记录 lastEventId
    //    - "delay"/其他 -> 忽略
    // 4) eventData 为空 ⇒ 丢弃该事件（不产生输出）
    // 5) 若 eventData 以 "\n" 结尾，只裁掉最后一个 "\n"
    // 6) eventData == "[DONE]" ⇒ .done，其余 ⇒ .data(eventData)
}

// 消费
for try await line in session.bytes(for: request) { ... }   // 或 URLSessionDataDelegate 增量回调
```

**必须注意**：
- 不要用 `URLSession.data(for:)`（会缓冲整个响应，破坏流式）。
- 用 `URLSession.bytes(for:)` 或 `URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)`。
- 分帧必须**跨 chunk 保留 buffer**；SSE 事件可在任意字节处被切断，包括 `\r\n\r\n` 中间。
- `URLSession` 默认会带 `Accept-Encoding: gzip`，需确认逐块解压正常；必要时设
  `Accept-Encoding: identity`。
- 取消：`Task.cancel()` 中止 `URLSessionDataTask`（ST 用 `AbortController`，`chat-completions.js:2630-2634`）。

### 1.7 非流式响应结构

上游返回标准 `chat.completion` 对象，ST **原样透传**（`chat-completions.js:2696-2700`）。
客户端读取（`public/script.js:6291-6299`）：

```js
case 'openai':
    return data?.content?.filter(p => p.type === 'text')?.map(p => p.text)?.join('\n\n')
        ?? data?.choices?.[0]?.message?.content
        ?? data?.choices?.[0]?.text
        ?? data?.text
        ?? data?.message?.content?.[0]?.text
        ?? data?.message?.tool_plan
        ?? '';
```

`Array.isArray(result)` 时再 `map(x => x.text).join('')`（Mistral 内容数组，`:6299`）。
多模态图片从 `data.choices[0].message.images[].image_url.url` 取（`public/script.js:6214-6220`）。

---

## 2. Anthropic（Claude）路径

### 2.1 URL / 认证 / 请求体

常量 `API_CLAUDE = 'https://api.anthropic.com/v1'`（`chat-completions.js:74`）。
URL：`new URL(reverse_proxy || API_CLAUDE).toString()`，端点直接 `apiUrl + '/messages'`
（`:231`、`:410`）。

请求头（`:414-419`）：

```js
headers: {
    'Content-Type': 'application/json',
    'anthropic-version': '2023-06-01',
    'x-api-key': apiKey,
    ...additionalHeaders,   // 'anthropic-beta'
}
```

`anthropic-beta` 是逗号连接的数组（`:246-247`、`:404-406`）：
`output-128k-2025-02-19`、`context-1m-2025-08-07` 恒在；使用工具时追加 `tools-2024-05-16`（`:290`）；
启用提示缓存时追加 `prompt-caching-2024-07-31`、`extended-cache-ttl-2025-04-11`（`:334-337`）；
使用 verbosity 时追加 `effort-2025-11-24`（`:399`）。

请求体（`:269-279`）：

```js
const requestBody = {
    system: [],                       // 仅在 use_sysprompt 时保留，否则 delete（:280-288）
    messages: convertedPrompt.messages,
    model: request.body.model,
    max_tokens: request.body.max_tokens,     // 必填
    stop_sequences: stopSequences,           // 恒为数组（可能为空）
    temperature: request.body.temperature,
    top_p: request.body.top_p,
    top_k: request.body.top_k,
    stream: request.body.stream,
};
```

**messages 规范化**（`src/prompt-converters.js:197-313`）：
- 开头的连续 `system` 消息被抽到 `system: [{type:'text', text}]` 数组，并从 messages 移除（`:200-220`）；
  `use_sysprompt` 为假时 messages 里的 `system` 全部降级为 `user`（`:253-268`）。
- 若抽完后 messages 为空，插入 `{role:'user', content: PROMPT_PLACEHOLDER}`（`:224-229`）。
- `tool` 角色 → `{role:'user', content:[{type:'tool_result', tool_use_id, content}]}`（`:244-251`）。
- assistant 的 `tool_calls` → `content:[{type:'tool_use', id, name, input}]`（`:235-242`）。
- 字符串 content → `[{type:'text', text}]`；空文本替换为零宽空格 `\u200b`（`:302`）。
- `image_url` → `{type:'image', source:{type:'base64', media_type, data}}`（`:280-294`）。
- 消息上的 `name` 被拼进文本前缀，然后 `delete message.name/tool_calls/tool_call_id`（`:296-312`）。

**采样参数与 thinking 的互斥**（`:339-391`）：
- `isLimitedSampling` 模型：`top_p < 1` 时删 `temperature`，否则删 `top_p`（`:339-345`）。
- `noSamplingModel`（opus-4-7/4-8/fable/opus-5/sonnet-5）：删 `temperature/top_p/top_k`（`:347-351`）。
- 自适应思考：`thinking = {type:'adaptive'}`，`output_config.effort` = low/medium/high/max，
  并删 `top_k`（`:358-367`）。
- 传统思考：`thinking = {type:'enabled', budget_tokens}`，`max_tokens` 若 ≤1024 会被自动加 1024，
  并删 `temperature/top_p/top_k`（`:372-391`）。预算算法见
  `src/prompt-converters.js:1124-1170`（min=1024，low=10%，medium=25%，high=50%，max=95%，
  非流式上限 21333）。
- `includeReasoning`（前端 `show_thoughts`）为真且为 noSamplingModel 时加
  `thinking.display = 'summarized'`（`:361-363`）。
- 工具：`requestBody.tools` 由 OpenAI 形状转成
  `{name, description, input_schema}`（去掉 `type:'function'` 外层，`:289-300`）；
  `tool_choice = {type: request.body.tool_choice}`。
- JSON schema：Claude 5.1 用 `output_config.format = {type:'json_schema', schema}`（`:304-310`），
  否则追加一个名为 schema.name 的工具并 `tool_choice = {type:'tool', name}`（`:311-319`）。
- 末尾 assistant prefill：thinking/无 prefill 模型会把最后一条 assistant 改成 `user`（`:393-395`）。

### 2.2 最小请求体 JSON 示例（Anthropic）

```json
{
  "system": [{ "type": "text", "text": "You are a helpful assistant." }],
  "messages": [
    { "role": "user", "content": [{ "type": "text", "text": "Hello!" }] }
  ],
  "model": "claude-sonnet-4-5",
  "max_tokens": 300,
  "stop_sequences": ["\nUser:"],
  "temperature": 1.0,
  "top_p": 1.0,
  "top_k": 0,
  "stream": true
}
```

### 2.3 流式响应（Anthropic Messages SSE）

上游是**带 `event:` 字段的命名 SSE**，事件序列：

```
message_start → (content_block_start → content_block_delta* → content_block_stop)* → message_delta → message_stop
```
期间可能穿插 `ping`；出错时 `error`。**没有 `[DONE]`**，以连接关闭结束。

分块示例：

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_01X","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":8}}

event: message_stop
data: {"type":"message_stop"}

```

**ST 的提取规则**（`public/scripts/openai.js:3226-3230`）：

```js
if (chat_completion_source === chat_completion_sources.CLAUDE) {
    if (show_thoughts) { state.reasoning += data?.delta?.thinking || ''; }
    return data?.delta?.text || '';
}
```

即 **ST 完全忽略 `event:` 名，只按 JSON 里有没有 `delta.text` / `delta.thinking` 判断**：
- `content_block_delta` + `delta.type == "text_delta"` → 取 `delta.text`（正文）。
- `content_block_delta` + `delta.type == "thinking_delta"` → 取 `delta.thinking`（思维链，
  只有 `show_thoughts` 时累积，**不进正文**）。
- `content_block_delta` + `delta.type == "signature_delta"` → 有 `delta.signature`（思维链签名），
  ST 在 `sse-stream.js` 的 `parseStreamData` 里不处理（落到"未知格式"分支被放行）。
- `content_block_delta` + `delta.type == "input_json_delta"` → `delta.partial_json`
  **ST 不解析**；工具调用改由 `ToolManager.parseToolCalls` 读 `content_block.type === 'tool_use'`
  （`public/scripts/tool-calling.js:488-499`）。
- `message_start` / `content_block_start` / `message_delta` / `message_stop` / `ping`
  在 `getStreamingReply` 下都返回 `''`（无副作用）。
- 在 `SmoothEventSourceStream` 下这些事件会抛 `Unknown event data format`，
  被 catch 后**原样放行**（`sse-stream.js:368-373`），因此不影响正文。

**Swift 建议**：按 `event:` 名做状态机更稳（能正确处理 `error` 事件），但文本提取必须与上面等价。
`input_json_delta` 要自行拼接 `partial_json` 才能得到完整工具参数。

### 2.4 非流式响应

`chat-completions.js:432-439`：

```js
const generateResponseJson = await generateResponse.json();
const responseText = generateResponseJson?.content?.[0]?.text || '';
const reply = { choices: [{ 'message': { 'content': responseText } }], content: generateResponseJson.content };
return response.send(reply);
```

即：读 `content[0].text`，重新包成 OpenAI 形状，同时把原始 `content` 数组放在 `content` 字段
（客户端从 `data.content.filter(p => p.type === 'text')` 取值，`public/script.js:6292`）。

**错误处理**（`:426-430`）：上游非 2xx ⇒ **HTTP 500 + `{error: true}`**，上游错误详情只写日志。
流式错误走 `forwardFetchResponse`（401→400 改写，正文透传）。

---

## 3. Google Gemini（AI Studio / Vertex AI）路径

### 3.1 URL 形式

常量：`API_MAKERSUITE = 'https://generativelanguage.googleapis.com'`、
`API_VERTEX_AI = 'https://us-central1-aiplatform.googleapis.com'`（`chat-completions.js:80-81`）。
版本：`getConfigValue('gemini.apiVersion', 'v1beta')`（`:679`）。

**AI Studio（makersuite）**（`:730`）：

```js
url = `${apiUrl.toString().replace(/\/$/, '')}/${apiVersion}/models/${model}:${responseType}?key=${apiKey}${stream ? '&alt=sse' : ''}`;
// responseType = stream ? 'streamGenerateContent' : 'generateContent'   (:680)
```

⇒ `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:streamGenerateContent?key=AIza...&alt=sse`

**Vertex AI**（`:687-728`）三种鉴权模式：
- `express`（API key）：`https://{region}-aiplatform.googleapis.com/v1/publishers/google/models/{model}:{responseType}?key={key}&alt=sse`；
  有 project id 时改用 `https://aiplatform.googleapis.com/v1/projects/{p}/locations/{region}/publishers/google/models/{model}:{responseType}?key=...&alt=sse`（`:696-698`）。
- `full`（service account）：`https://{region}-aiplatform.googleapis.com/v1/projects/{p}/locations/{region}/publishers/google/models/{model}:{responseType}?alt=sse`，
  头 `Authorization: <OAuth token>`（`:699-723`）。
- proxy：`{reverse_proxy}/v1/publishers/google/models/{model}:{responseType}?alt=sse`（`:726-727`）。
- `region === 'global'` 时 host 去掉 region 前缀（`:718-719`）。

**关键结论：流式一律用 `?alt=sse`，因此上游返回的是标准 SSE（`data: {...}` 行），
不是裸 JSON 数组。**（`chat-completions.js:697-698`、`:719`、`:721`、`:726`、`:730`）

### 3.2 请求体

`generationConfig`（`:502-512`）：

```js
const generationConfig = {
    stopSequences: request.body.stop,
    candidateCount: 1,
    maxOutputTokens: request.body.max_tokens,
    temperature: request.body.temperature,
    topP: request.body.top_p,
    topK: request.body.top_k || undefined,
    responseMimeType: responseMimeType,       // json_schema 时 'application/json'
    responseSchema: responseSchema,           // json_schema.value
    seed: request.body.seed,
};
```

主体（`:624-666`）：

```js
let body = {
    contents: prompt.contents,                 // [{role:'user'|'model', parts:[...]}]
    safetySettings: safetySettings,            // GEMINI_SAFETY + (Vertex: VERTEX_SAFETY)
    generationConfig: generationConfig,
};
if (useSystemPrompt && prompt.system_instruction.parts.length) {
    body.systemInstruction = prompt.system_instruction;   // {parts:[{text}]}
}
if (tools.length) { body.tools = tools; body.toolConfig = {functionCallingConfig}; }
```

细节：
- `contents` 由 `convertGooglePrompt` 生成（`src/prompt-converters.js:432-...`）：
  - `system`/`tool` 角色 → `user`；`assistant` → `model`（`:462-467`）；
    新模型（`gemini-3.[67]-flash|gemini-3.5-flash-lite`）的末尾 model turn 会改回 `user`（避免 prefill 被拒）。
  - 文本 → `{text}`；`image_url`/`video_url`/`audio_url`（data URL）→
    `{inlineData:{mimeType, data}}`，Gemini 3 还带 `{mediaResolution:{level}}`（`:515-537`、`:561-572`）。
  - `tool_calls` → `{functionCall:{name, args}}`（可带 `thoughtSignature`）；
    `tool_call_id` → `{functionResponse:{name, response}}`（`:541-560`）。
  - `system_instruction = {parts: sysPrompt.map(text => ({text}))}`（`:453`）。
- 安全设置：全部 `threshold: 'OFF'`（`src/constants.js:141-185`）。
- 思考配置：`generationConfig.thinkingConfig = {includeThoughts, thinkingBudget | thinkingLevel}`
  （`:603-622`），预算算法 `src/prompt-converters.js:1182+`。
- 图像生成模型：`generationConfig.responseModalities = ['text','image']`（`:550-563`）。
- 采样参数删除：`noSamplingModel`（`gemini-3.[67]-flash|gemini-3.5-flash-lite`）删
  `temperature/topP/topK/candidateCount`（`:529`、`:543-548`）；空 `stopSequences` 会被 delete（`:539-541`）。

### 3.3 最小请求体 JSON 示例（Gemini）

```json
{
  "contents": [
    { "role": "user", "parts": [{ "text": "Hello!" }] }
  ],
  "systemInstruction": { "parts": [{ "text": "You are a helpful assistant." }] },
  "safetySettings": [
    { "category": "HARM_CATEGORY_HARASSMENT", "threshold": "OFF" },
    { "category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "OFF" },
    { "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "OFF" },
    { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "OFF" },
    { "category": "HARM_CATEGORY_CIVIC_INTEGRITY", "threshold": "OFF" }
  ],
  "generationConfig": {
    "candidateCount": 1,
    "maxOutputTokens": 300,
    "temperature": 1.0,
    "topP": 1.0,
    "topK": 0
  }
}
```

HTTP：

```http
POST /v1beta/models/gemini-3.7-flash:streamGenerateContent?key=AIza...&alt=sse HTTP/1.1
Content-Type: application/json
```

（AI Studio 无 `Authorization` 头；Vertex proxy 模式额外带 `Authorization`。）

### 3.4 流式响应分块示例（Gemini，`alt=sse`）

```
data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":5,"totalTokenCount":5},"modelVersion":"gemini-3.7-flash"}

data: {"candidates":[{"content":{"parts":[{"text":"!"}],"role":"model"},"index":0,"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7},"modelVersion":"gemini-3.7-flash"}

```

**注意：Gemini 的 SSE 没有 `[DONE]` 标记**，流以连接关闭结束；`finishReason` 出现在最后一个 chunk 的
`candidates[0]` 上（上游约定取值：`STOP` / `MAX_TOKENS` / `SAFETY` / `RECITATION` / `OTHER`；
ST 不读取该字段）。

**ST 的提取规则**（`public/scripts/openai.js:3231-3246`）：

```js
const inlineData = data?.candidates?.[0]?.content?.parts?.filter(x => x.inlineData && !x.thought)?.map(x => x.inlineData) || [];
if (inlineData.length) state.images.push(...inlineData.map(x => `data:${x.mimeType};base64,${x.data}`));
if (show_thoughts) {
    state.reasoning += (data?.candidates?.[0]?.content?.parts?.filter(x => x.thought)?.map(x => x.text)?.[0] || '');
}
const parts = data?.candidates?.[0]?.content?.parts || [];
parts.forEach(part => { if (part.thoughtSignature && typeof part.text === 'string') state.signature = part.thoughtSignature; });
return data?.candidates?.[0]?.content?.parts?.filter(x => !x.thought)?.map(x => x.text)?.[0] || '';
```

要点：
- 正文 = `candidates[0].content.parts` 中 **第一个 `!thought` 且带 `text` 的 part**
  （注意只取 `[0]`，不是拼接）。
- 思维链 = 带 `thought: true` 的 part 的 `text`（同样只取第一个），只在 `show_thoughts` 时累积。
- 图片 = `inlineData`（非 thought）→ `data:{mimeType};base64,{data}`。
- `thoughtSignature` 保存在 `state.signature`，用于回传。
- `safetyRatings` / `promptFeedback` / `finishReason` **ST 流式路径完全不读**。
- `SmoothEventSourceStream` 的 `parseStreamData` 对 Gemini 有额外处理
  （`sse-stream.js:150-187`）：多 part 时在非末 part 的最后一个字符后补 `\n\n`；
  `candidates[0].index > 0` 视为非主 swipe 直接丢弃。

### 3.5 非流式响应

`chat-completions.js:758-785`：

```js
const candidates = generateResponseJson?.candidates;
if (!candidates || candidates.length === 0) {
    let message = `${apiName} API returned no candidate`;
    if (generateResponseJson?.promptFeedback?.blockReason)
        message += `\nPrompt was blocked due to : ${generateResponseJson.promptFeedback.blockReason}`;
    return response.send({ error: { message } });
}
const responseContent = candidates[0].content ?? candidates[0].output;
const responseText = typeof responseContent === 'string' ? responseContent
    : responseContent?.parts?.filter(part => !part.thought)?.map(part => part.text)?.join('\n\n');
// 空文本且无 functionCall/inlineData ⇒ { error: { message } }
const reply = { choices: [{ 'message': { 'content': responseText } }], responseContent };
```

**错误处理**（`:750-756`）：上游非 2xx ⇒ HTTP **500** + 上游原始 JSON（`tryParse(errorText) ?? {error:true}`）。
空候选/被拦截 ⇒ HTTP 200 + `{error:{message}}`，消息里含 `promptFeedback.blockReason`。

---

## 4. 其他供应商

### 4.1 供应商矩阵（chat completions）

URL 常量见 `src/endpoints/backends/chat-completions.js:73-101`；实现函数行号见下表。

| source（枚举值） | 实现位置 | URL | 认证 | 协议族 | 流式格式 | 文本提取路径 |
|---|---|---|---|---|---|---|
| `openai` | `:2281-2300` | `{reverse_proxy \|\| https://api.openai.com/v1}/chat/completions` | `Authorization: Bearer` | OpenAI | SSE + `[DONE]` | `choices[0].delta.content` |
| `custom` | `:2394-2421` | `{custom_url}/chat/completions` | Bearer（可空）+ 自定义头 | OpenAI | SSE + `[DONE]` | 同上 |
| `openrouter` | `:2301-2393` | `https://openrouter.ai/api/v1/chat/completions` | Bearer + `HTTP-Referer`/`X-Title` | OpenAI 扩展 | SSE + `[DONE]` | `delta.content` / `delta.reasoning` |
| `mistralai` | `sendMistralAIRequest :881-964` | `{reverse_proxy \|\| https://api.mistral.ai/v1}/chat/completions` | Bearer | OpenAI-ish | SSE | `delta.content`（可为数组） |
| `cohere` | `sendCohereRequest :971-1064` | `https://api.cohere.ai/v2/chat` | Bearer | Cohere v2 | 自有 SSE（`type` 事件） | `delta.message.content.text` |
| `deepseek` | `sendDeepSeekRequest :1071-1176` | `{reverse_proxy \|\| https://api.deepseek.com/beta}/chat/completions` | Bearer | OpenAI | SSE + `[DONE]` | `delta.content` / `delta.reasoning_content` |
| `xai` | `sendXaiRequest :1183-1282` | `{reverse_proxy \|\| https://api.x.ai/v1}/chat/completions` | Bearer | OpenAI | SSE | 同上 |
| `perplexity` | `:2422-2437` | `https://api.perplexity.ai/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `groq` | `:2438-2453` | `https://api.groq.com/openai/v1/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `fireworks` | `:2454-2475` | `https://api.fireworks.ai/inference/v1/chat/completions` | Bearer + `x-session-affinity` | OpenAI | SSE | 通用分支 |
| `nanogpt` | `:2476-2511` | `https://nano-gpt.com/api/v1/chat/completions` | Bearer + `X-Provider`/`X-Billing-Mode` | OpenAI | SSE | 通用分支 |
| `aimlapi` | `sendAimlapiRequest :1289-1387` | `https://api.aimlapi.com/v1/chat/completions` | Bearer + Referer/Title | OpenAI | SSE | 通用分支 |
| `electronhub` | `sendElectronHubRequest :1394-1499` | `https://api.electronhub.ai/v1/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `chutes` | `sendChutesRequest :1506-1600` | `https://llm.chutes.ai/v1/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `minimax` | `sendMinimaxRequest :1607-1681` | `https://api.minimax.io/v1` 或 `https://api.minimaxi.com/v1` + `/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `pollinations` | `:2512-2530` | `https://gen.pollinations.ai/v1`（匿名 `https://text.pollinations.ai/v1`） | Bearer（匿名时 `Bearer anonymous`） | OpenAI | SSE | 通用分支 |
| `moonshot` | `:2531-2542` | `{reverse_proxy \|\| https://api.moonshot.ai/v1}/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `zai` | `:2551-2565` | `https://api.z.ai/api/paas/v4` 或 `/api/coding/paas/v4` + `/chat/completions` | Bearer + `Accept-Language` | OpenAI | SSE | 通用分支 |
| `siliconflow` | `:2566-2575` | `https://api.siliconflow.com/v1` 或 `https://api.siliconflow.cn/v1` + `/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `workers_ai` | `:2576-2593` | `https://api.cloudflare.com/client/v4/accounts/{id}/ai/v1/chat/completions` | Bearer | OpenAI | SSE | 通用分支 |
| `azure_openai` | `sendAzureOpenAIRequest :1687-1774` | `{azure_base_url}/openai/deployments/{deployment}/chat/completions?api-version={v}` | **`api-key`** | OpenAI | SSE | 通用分支 |
| `ai21` | `sendAI21Request :800-874` | `https://api.ai21.com/studio/v1/chat/completions` | Bearer | OpenAI-ish | SSE | 通用分支 |
| `claude` | `sendClaudeRequest :230-443` | `{reverse_proxy \|\| https://api.anthropic.com/v1}/messages` | `x-api-key` + `anthropic-version` | Anthropic | 命名 SSE | `delta.text` / `delta.thinking` |
| `makersuite` | `sendMakerSuiteRequest :454-793` | `https://generativelanguage.googleapis.com/{v1beta}/models/{m}:streamGenerateContent?key=&alt=sse` | `?key=` | Gemini | SSE（`alt=sse`） | `candidates[0].content.parts[].text` |
| `vertexai` | 同上 `:687-728` | `https://{region}-aiplatform.googleapis.com/v1/projects/{p}/locations/{r}/publishers/google/models/{m}:streamGenerateContent?alt=sse` | OAuth Bearer / `?key=` | Gemini | SSE（`alt=sse`） | 同上 |
| `cometapi` | `:2543-2550` | — | — | — | — | **已禁用**：`throw new Error('This provider is temporarily disabled.')` |

非 OpenAI 协议的关键请求体差异：

```jsonc
// Mistral (:898-915)
{ "model", "messages", "temperature", "top_p", "frequency_penalty", "presence_penalty",
  "max_tokens", "stream", "safe_prompt", "random_seed": <seed，-1 时为 undefined>, "stop",
  "tools", "tool_choice", "response_format" }

// Cohere v2 (:998-1024)
{ "stream": bool, "model", "messages": [...], "temperature", "max_tokens",
  "k": <top_k>, "p": <top_p>, "seed", "stop_sequences": [...],
  "frequency_penalty", "presence_penalty", "documents": [], "tools": [],
  "safety_mode": "OFF" /* 仅 model 以 08-2024 结尾 */, "response_format" }

// DeepSeek (:1126-1139)
{ "messages", "model", "temperature", "max_tokens", "stream", "presence_penalty",
  "frequency_penalty", "top_p", "stop", "seed",
  "thinking": { "type": "enabled"|"disabled" } /* = include_reasoning */, "reasoning_effort" }

// AI21 (:827-837) —— 注意没有 top_k / 惩罚项
{ "messages", "model", "max_tokens", "temperature", "top_p", "stop", "stream", "tools" }

// xAI (:1232-1245)
{ "messages", "model", "temperature", "max_tokens", "max_completion_tokens", "stream",
  "presence_penalty", "frequency_penalty", "top_p", "seed", "n",
  "reasoning_effort": "high"|"low"   /* 非 high 一律降级为 low，:1216 */ }

// OpenRouter 扩展 (:2307-2365)
{ ...标准字段, "transforms", "plugins", "reasoning": {"exclude": !include_reasoning, "effort"?},
  "min_p", "top_a", "repetition_penalty", "provider": {"allow_fallbacks", "order", "quantizations"},
  "route": "fallback", "verbosity", "safety_settings" /* model 匹配 google/gemini 时 */ }

// Azure (:1701-1733) —— 白名单字段 AZURE_OPENAI_KEYS (src/constants.js:440-457)
["messages","temperature","frequency_penalty","presence_penalty","top_p","max_tokens",
 "max_completion_tokens","stream","logit_bias","stop","n","logprobs","seed","tools",
 "tool_choice","reasoning_effort"]
```

Cohere 流式是**自有事件协议**（不是 `choices`），事件 `type` 取值形如
`message-start` / `content-delta` / `content-start` / `tool-plan-delta` / `tool-call-start` /
`tool-call-delta` / `tool-call-end` / `message-end`；文本在 `delta.message.content.text`
（`public/scripts/openai.js:3247-3248`、`public/scripts/tool-calling.js:472-487`）。

### 4.2 可复用 OpenAI 协议的供应商清单

**直接复用 OpenAI 实现（`{base}/chat/completions` + `Authorization: Bearer` + 标准 SSE）**：

```
openai, custom, groq, perplexity, fireworks, nanogpt, pollinations, moonshot, zai,
siliconflow, workers_ai, aimlapi, electronhub, chutes, minimax, openrouter, mistralai,
deepseek, xai, ai21
```

按实现它们所需的**额外分支**排序（复杂度递增）：

1. **纯直通**（无额外字段）：`openai`、`custom`、`groq`、`perplexity`、`siliconflow`、`zai`、`aimlapi`
2. **额外采样参数**：`chutes`（`repetition_penalty`/`min_p`/`top_k`/`logit_bias`）、
   `electronhub`（`top_k`/`logit_bias`）、`workers_ai`（`repetition_penalty`）、
   `mistralai`（`safe_prompt`/`random_seed`）、`ai21`（字段更少）
3. **thinking 开关**：`deepseek`、`moonshot`、`zai`（`thinking:{type}`）
4. **额外 header**：`openrouter`、`aimlapi`（Referer/Title）、`fireworks`（session affinity）、
   `nanogpt`（`X-Provider`/`X-Billing-Mode`）、`zai`（`Accept-Language`）
5. **URL 形状不同**：`azure_openai`（deployment 路径 + `api-key` + `api-version` query）
6. **响应流需二次解析**：`cohere`（自有事件类型）
7. **完全独立协议**：`claude`、`makersuite`、`vertexai`

### 4.3 文本补全（非 chat）后端

服务端：`src/endpoints/backends/text-completions.js`。URL 拼接基准：
`let url = trimV1(baseUrl)`，再按类型追加路径（`:294-324`）：

| api_type | 端点路径 | 完整示例 |
|---|---|---|
| `ooba`（text-generation-webui） | `+ '/v1/completions'` | `http://127.0.0.1:5000/v1/completions` |
| `vllm` | `+ '/v1/completions'` | — |
| `aphrodite` | `+ '/v1/completions'` | — |
| `tabby` | `+ '/v1/completions'` | — |
| `koboldcpp` | `+ '/v1/completions'` | — |
| `togetherai` | `+ '/v1/completions'` | `https://api.together.xyz/v1/completions` |
| `infermaticai` | `+ '/v1/completions'` | `https://api.totalgpt.ai/v1/completions` |
| `featherless` | `+ '/v1/completions'` | `https://api.featherless.ai/v1/completions` |
| `generic` | `+ '/v1/completions'` | 用户自填 |
| `huggingface` | `+ '/v1/completions'` | 用户自填 |
| `dreamgen` | `+ '/api/openai/v1/completions'` | `https://dreamgen.com/api/openai/v1/completions` |
| `mancer` | `+ '/oai/v1/completions'` | `https://neuro.mancer.tech/oai/v1/completions` |
| `llamacpp` | `+ '/completion'` | （注意：单数、无 `/v1`） |
| `ollama` | `+ '/api/generate'` | 原生 Ollama |
| `openrouter` | `+ '/v1/chat/completions'` | ⚠️ 唯一走 chat 的 textgen 类型 |

（`:297-324`；枚举 `src/constants.js:222-238`，客户端枚举 `public/scripts/textgen-settings.js:31-46`；
默认 server 见 `public/scripts/textgen-settings.js:122-129`。）

请求体：客户端把整个 `params` 对象发给 ST，服务端再按类型白名单 `_.pickBy` 过滤
（`:336-399`）：

- `togetherai` → `TOGETHERAI_KEYS`（`src/constants.js:306-319`）
- `infermaticai` → `INFERMATICAI_KEYS`（`:240-261`）
- `featherless` → `FEATHERLESS_KEYS`（`:263-303`）
- `generic` → `OPENAI_KEYS`（`:341-356`），`stop` 截断到 4 条（`:357`）
- `openrouter` → `OPENROUTER_KEYS`（`:377-395`）
- `vllm` → `VLLM_KEYS`（`:398-438`）
- `ollama` → 重写为原生格式（`:391-398`）：

```json
{
  "model": "...",
  "prompt": "...",
  "stream": true,
  "keep_alive": -1,
  "raw": true,
  "options": { "num_predict": 300, "temperature": 1.0, "top_p": 1.0, "repeat_penalty": 1.1, "...": "..." }
}
```
（`options` 白名单 = `OLLAMA_KEYS`，`src/constants.js:322-338`）

**原始 params 全量字段**见 `public/scripts/textgen-settings.js:1600-1769`（约 80 个字段，
含 `max_new_tokens`/`max_tokens`/`n_predict`/`num_predict` 四个等价输出长度别名，
`rep_pen`/`repetition_penalty`/`repeat_penalty` 三个等价惩罚别名）。

**流式格式**：

- 除 Ollama 外，全部**原样 pipe 上游 SSE**（`text-completions.js:404-407`），
  文本按 `parseStreamData` 的 OpenAI 分支 `choices[0].text` 读取
  （`sse-stream.js:219-230`）。
- Ollama 是**裸 JSON 行流（NDJSON）**，ST 用 `parseOllamaStream` 转成 SSE
  （`text-completions.js:29-72`）：逐行 `JSON.parse`，取 `json.response`（正文）与
  `json.thinking`（思维链），包成 `{choices:[{text, thinking}]}` 写 `data: ...\n\n`，
  结束时补 `data: [DONE]\n\n`（`:61`）。
- **Swift 侧对 Ollama 应直接按 NDJSON 解析**，不要走 SSE 分帧。
- `llamacpp` 的 logprobs 在 `data.completion_probabilities`（`public/script.js:6251-6253`）。

**非流式响应提取**（`public/script.js:6287-6288`）：

```js
case 'textgenerationwebui':
    return data.choices?.[0]?.text ?? data.choices?.[0]?.message?.content
        ?? data.content ?? data.response ?? data[0]?.content ?? '';
```

**Kiwi / KoboldCpp 原生路径**（`src/endpoints/backends/kobold.js:11-141`）：

- URL：流式 `${api_server}/extra/generate/stream`，非流式 `${api_server}/v1/generate`（`:97`）。
- 中止：`${api_server}/extra/abort`（`:26`、`text-completions.js:89`）。
- 请求体（`:40-81`）：`prompt`、`use_story/use_memory/use_authors_note/use_world_info` 全 `false`、
  `max_context_length`、`max_length`，以及（非 GUI 模式）`rep_pen`、`rep_pen_range`、`rep_pen_slope`、
  `temperature`、`tfs`、`top_a`、`top_k`、`top_p`、`min_p`、`typical`、`sampler_order`、
  `singleline`、`use_default_badwordsids`、`mirostat*`、`grammar`、`sampler_seed`、`stop_sequence`。
- 有 `403`/`503` 时**重试 50 次、间隔 2500ms**（`:93-94`、`:124-129`）。
- 错误体：`{ error: { message } }`，message 取 `errorJson?.detail?.msg`（`:109-115`）。

---

## 5. 反向代理 / 自定义端点

- **可配置 base URL 的源**（`proxySupportedSources`，`public/scripts/openai.js:2739-2749`）：
  `claude, openai, mistralai, makersuite, vertexai, deepseek, xai, zai, moonshot`。
  这些源允许 `reverse_proxy` 覆盖官方 base；此时 **API key 用 `proxy_password`**
  （`chat-completions.js:2283`、`:232`、`:477`、`:1073`、`:1185` 等）。
- **无反向代理但可填任意 URL 的源**：`custom`（`custom_url`，`:2395`）和所有 textgen 类型
  （`api_server`，`text-completions.js:281`）。
- URL 校验：UI 用 `isValidUrl`（`new URL()` 能否解析，`public/scripts/utils.js:173-180`）；
  用户需**自行确认**弹窗（`public/scripts/openai.js:537-563`，可记住选择）。
- **规范化规则汇总**：
  1. OpenAI/Mistral/DeepSeek/xAI/Z.AI/Moonshot/Claude：`new URL(x).toString()`，无补全、无去尾斜杠。
  2. Gemini：额外 `.replace(/\/$/, '')` 去一个尾斜杠，再拼 `/{version}/models/...`。
  3. textgen：`trimV1(x)` = 去尾斜杠 + 去尾 `/v1`，然后由代码补正确路径。
  4. `custom`：**零规范化**，直接字符串拼接。
- `localhost` → `127.0.0.1` 的替换只在 textgen / kobold 路径
  （`text-completions.js:104-106`、`:276-278`；`kobold.js:14-16`），chat 路径不做。

---

## 6. 图片 / 多模态与文件附件

**内部表示**（浏览器侧 `Message` 类，`public/scripts/openai.js:3624-3651`）：
`content` 可以是字符串，也可以是 parts 数组：

```jsonc
[
  { "type": "text", "text": "..." },
  { "type": "image_url", "image_url": { "url": "data:image/png;base64,iVBOR...", "detail": "auto" } },
  { "type": "video_url", "video_url": { "url": "data:video/mp4;base64,...", "detail": "auto" } },
  { "type": "audio_url", "audio_url": { "url": "data:audio/mpeg;base64,..." } }
]
```

- 非 data URL 的图片会先 `fetch` 转 base64（`:3627-3637`），再按
  `oai_settings.inline_image_quality`（默认 `'auto'`，`:499`）设置 `detail`。
- **OpenAI 源**（`chat-completions.js:2300`）：`embedOpenRouterMedia(messages, {audio:true, video:false})`
  —— 图片保持 `image_url` 不变；`audio_url` 被转成
  `{type:'input_audio', input_audio:{format:'mp3'|'wav', data:<base64>}}`（`src/prompt-converters.js:1351-1367`）；
  视频不变（OpenAI 不支持）。
- **OpenRouter 源**（`:2373`）：`{audio:true, video:true}`，`video_url` 原样保留。
- **Claude**（`src/prompt-converters.js:280-294`）：
  `{type:'image', source:{type:'base64', media_type, data}}`（从 data URL 解出 mime + base64）。
  assistant 消息里的图片会被搬到下一条 user 消息（`:315+`）。
- **Gemini**（`src/prompt-converters.js:515-537`、`:561-572`）：
  `{inlineData:{mimeType, data}}`，Gemini 3 可带 `mediaResolution`。
- **上传文件**（非图片，如 txt/pdf）走 ST 自己的 `src/endpoints/files.js`，转成**文本**注入 prompt，
  不涉及 LLM 多模态协议。
- `isImageInliningSupported()` / `isVideoInliningSupported()` / `isAudioInliningSupported()`
  （`public/scripts/openai.js:6226`、`:6366`、`:6406`）按 source+model 决定 UI 是否允许内联。

---

## 7. 采样参数默认值来源

Chat completions 默认值定义在 `public/scripts/openai.js:411-518`（`default_settings`）：

| 参数 | 默认值 | 位置 |
|---|---|---|
| `temp_openai`（temperature） | `1.0` | `:413` |
| `freq_pen_openai` | `0` | `:414` |
| `pres_pen_openai` | `0` | `:415` |
| `top_p_openai` | `1.0` | `:416` |
| `top_k_openai` | `0` | `:417` |
| `min_p_openai` | `0` | `:418` |
| `top_a_openai` | `0` | `:419` |
| `repetition_penalty_openai` | `1` | `:420` |
| `stream_openai` | `false` | `:421` |
| `openai_max_context` | `max_4k` | `:422` |
| `openai_max_tokens` | `300` | `:423` |
| `seed` | `-1`（= 不发送） | `:514` |
| `n` | `1` | `:515` |
| `show_thoughts` | `true` | `:507` |
| `reasoning_effort` | `'auto'` | `:508` |
| `verbosity` | `'auto'` | `:509` |
| `inline_image_quality` | `'auto'` | `:499` |
| `media_inlining` | `true` | `:498` |

映射到请求（`createGenerationParameters`，`:2803-2828`）：
`temperature ← Number(temp_openai)`、`frequency_penalty ← freq_pen_openai`、
`presence_penalty ← pres_pen_openai`、`top_p ← top_p_openai`、`max_tokens ← openai_max_tokens`。

**供应商侧局部覆盖**（同函数后半段）：
- Cohere：`top_p` 夹到 `[0.01, 0.99]`，两个 penalty 夹到 `[0, 1]`（`:2929-2937`）。
- Gemini：`stop` 限 5 条且长度 `1..16`（`:2905-2909`）。
- DeepSeek：`top_p = top_p || Number.EPSILON`（`:2955-2957`）。
- Z.AI：`top_p = top_p || 0.01`（`:2993-2994`）。
- MiniMax：`temperature` 夹到 `(0, 1]`（`:3011-3014`）。
- Workers AI：`top_p >= 0.001`、`top_k <= 50`（`:3017-3025`）。
- Mistral：`safe_prompt = false`（`:2918`）。

Text completion 默认值在 `public/scripts/textgen-settings.js` 的
`textgenerationwebui_settings` 默认对象中；请求体构造见 `:1600-1769`。

---

## 8. Swift 实现检查清单

1. **三个协议族 + 两个传输格式**：
   - OpenAI 兼容（SSE + `[DONE]`）
   - Anthropic（命名 SSE，无 `[DONE]`，靠连接关闭）
   - Gemini（SSE with `alt=sse`，无 `[DONE]`）
   - Ollama textgen（NDJSON，非 SSE）
   - KoboldCpp 原生（`/extra/generate/stream`，SSE）
2. **SSE 分帧**必须逐字复刻 `sse-stream.js:17-67`（三种换行组合、`data:` 多行拼接、
   空 data 跳过、只裁最后一个 `\n`）。
3. **文本提取**用 `getStreamingReply` 的分支规则（`openai.js:3222-3306`），
   特别注意 `??` 链语义（空字符串会短路）。
4. **reasoning 与正文分离**：`reasoning_content`/`reasoning`/`thinking`/`thought` parts
   只在 `showThoughts` 时进 reasoning 缓冲。
5. **错误模型**：优先读 `error.message` → `error.code` → `error.type` → `detail.error` →
   `message`；非流式时 ST 只传 `statusText`，Swift 可直接读上游 body（更好）；
   流式时注意 401→400 的历史行为不必模仿。
6. **URL**：base 必须含 `/v1`（用户责任）；`custom` 不做规范化；Gemini 去一个尾斜杠。
7. **取消**：`Task` 取消 → `URLSessionDataTask.cancel()`。
8. **多 swipe**：`choices[0].index > 0` 时文本进独立缓冲；`n > 1` 时 OpenAI 才发送 `n`。
9. **`stream_options` 不发送**；`user` 仅在需要随机化时发送。
10. **超时**：服务端对 textgen 显式设置 `timeout: 0`（`text-completions.js:331`），
    chat 路径未设 → `node-fetch` 默认无超时。Swift 建议对流式请求禁用
    `timeoutIntervalForRequest`（或设很长），否则长思考会被切断。
