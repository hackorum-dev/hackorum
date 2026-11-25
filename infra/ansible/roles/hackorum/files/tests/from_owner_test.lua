-- luajit from_owner_test.lua <rendered from_owner.lua>
local map = {
  ['receiver@ci.hackorum.test'] = 'receiver@ci.hackorum.test',
  ['dutow@ci.hackorum.test'] = 'dutow@ci.hackorum.test',
  ['zsolt.parragi@ci.hackorum.test'] = 'dutow@ci.hackorum.test',
  ['zed@ci.hackorum.test'] = 'zed@ci.hackorum.test',
}
local cb
rspamd_config = {
  add_map = function(_, o) assert(o.type == 'hash' and o.url == 'file:///tmp/docker-mailserver/sender-login.map'); return { get_key = function(_, k) return map[k] end } end,
  register_symbol = function(_, o) assert(o.name == 'FROM_OWNER_CHECK' and o.type == 'prefilter' and o.flags == 'explicit_disable'); cb = o.callback end,
}
dofile(arg[1])
local function run(user, from)
  local res
  cb({ get_user = function() return user end, get_from = function(_, t) assert(t == 'mime'); return from end,
       set_pre_result = function(_, action, msg) res = action .. ': ' .. msg end })
  return res
end
local function a(addr) return { { addr = addr } } end
local rej = 'reject: From address not owned by login'
local cases = {
  { 'inbound, no user', nil, a('anyone@example.com'), nil },
  { 'app exempt', 'app@ci.hackorum.test', a('noreply@ci.hackorum.test'), nil },
  { 'app exempt, case', 'App@CI.hackorum.test', a('x@elsewhere.org'), nil },
  { 'own login', 'dutow@ci.hackorum.test', a('dutow@ci.hackorum.test'), nil },
  { 'own alias', 'dutow@ci.hackorum.test', a('Zsolt.Parragi@ci.hackorum.test'), nil },
  { 'logged in as alias, from login', 'zsolt.parragi@ci.hackorum.test', a('dutow@ci.hackorum.test'), nil },
  { 'receiver as itself', 'receiver@ci.hackorum.test', a('receiver@ci.hackorum.test'), nil },
  { 'foreign mailbox', 'dutow@ci.hackorum.test', a('zed@ci.hackorum.test'), rej },
  { 'system name', 'dutow@ci.hackorum.test', a('security@ci.hackorum.test'), rej },
  { 'outside domain', 'dutow@ci.hackorum.test', a('me@example.com'), rej },
  { 'receiver as other', 'receiver@ci.hackorum.test', a('dutow@ci.hackorum.test'), rej },
  { 'unknown login', 'ghost@ci.hackorum.test', a('ghost@ci.hackorum.test'), rej },
  { 'no From', 'dutow@ci.hackorum.test', nil, rej },
  { 'empty From', 'dutow@ci.hackorum.test', {}, rej },
  { 'two From', 'dutow@ci.hackorum.test', { { addr = 'dutow@ci.hackorum.test' }, { addr = 'zed@ci.hackorum.test' } }, rej },
}
local bad = 0
for _, c in ipairs(cases) do
  local got = run(c[2], c[3])
  if got ~= c[4] then bad = bad + 1; print('FAIL ' .. c[1] .. ': got ' .. tostring(got)) end
end
if bad > 0 then os.exit(1) end
print(#cases .. ' lua cases ok')
