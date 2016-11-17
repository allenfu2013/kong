local cache = require "kong.tools.database_cache"
local pl_tablex = require "pl.tablex"
local singletons = require "kong.singletons"
local dns_client = require "resty.dns.client"  -- due to startup/require order, cannot use the one from 'singletons' here
local ring_balancer = require "resty.dns.balancer"

local toip = dns_client.toip

local empty = pl_tablex.readonly {}

--===========================================================
-- Ring-balancer based resolution
--===========================================================
local balancers = {}  -- table holding our balancer objects, indexed by upstream name

-- caching logic;
-- we retain 3 entities;
-- 1) list of upstreams, to be invalidated on any upstream change
-- 2) individual upstreams, to be invalidated on individual basis
-- 3) target history for an upstream, invalidated when;
--    a) along with the upstream it belongs to
--    b) upon any target change for the upstream (can only add entries)
-- Distinction between 1 and 2 makes it possible to invalidate individual
-- upstreams, instead of all at once forcing to rebuild all balancers

-- Implements a simple dictionary with all upstream-ids indexed
-- by their name. 
local function load_upstreams_dict_into_memory()
  local upstreams, err = singletons.dao.upstreams:find_all()
  if err then
    return nil, err
  end
  
  -- build a dictionary, indexed by the upstream name
  local upstreams_dict = {}
  for _, up in ipairs(upstreams) do
    upstreams_dict[up.name] = up.id
  end

  -- check whether any of our existing balancers has been deleted
  for upstream_name in pairs(balancers) do
    if not upstreams_dict[upstream_name] then
      -- this one was deleted, so also clear the balancer object
      balancers[upstream_name] = nil
    end
  end

  return upstreams_dict
end

-- loads a single upstream entity
local function load_upstream_into_memory(upstream_id)
  local upstream, err = singletons.dao.upstreams:find {id = upstream_id}
  if not upstream then
    return nil, err
  end
  
  upstream = upstream[1]  -- searched by id, so only 1 row in the returned set
  
  -- because we're reloading the upstream, it was updated, so we must also
  -- re-created the balancer
  balancers[upstream.name] = nil
  
  local b, err = ring_balancer.new({
      wheelsize = upstream.slots,
      order = upstream.orderlist,
      dns = dns_client,
    })
  if not b then return b, err end
  
  -- NOTE: we're inserting a foreign entity in the balancer, to keep track of
  -- target-history changes!
  b.__targets_history = {} 
  balancers[upstream.name] = b

  return upstream
end

-- finds and returns an upstream entity. This functions covers
-- caching, invalidation, db access, et al.
-- @return upstream table, or `false` if not found, or nil+error
local function get_upstream(upstream_name)
  local upstreams_dict, err = cache.get_or_set(cache.upstreams_dict_key(), load_upstreams_dict_into_memory)
  if err then
    return nil, err
  end

  local upstream_id = upstreams_dict[upstream_name]
  if not upstream_id then return false end -- no upstream by this name
  
  return cache.get_or_set(cache.upstream_key(upstream_id), load_upstream_into_memory)
end

-- loads the target history for an upstream
-- @param upstream_id Upstream uuid for which to load the target history
local function load_targets_into_memory(upstream_id)
  local target_history, err = singletons.dao.targets:find_all {upstream_id = upstream_id}
  if err then
    return nil, err
  end
  
  -- some raw data updates
  for _, target in ipairs(target_history) do
    -- split `target` field into `name` and `port`
    local port
    target.name, port = string.match(target.target, "^(.-):(%d+)$")
    target.port = tonumber(port)
    -- need exact order, so order by created time and uuid
    target.order = target.created_at..":"..target.id
  end
  
  -- order by time
  table.sort(target_history, function(a,b) return a.order<b.order end)

  return target_history
end

-- applies the history of lb transactions from index `start` forward
-- @param rb ring-balancer object
-- @param history list of targets/transactions to be applied
-- @param start the index where to start in the `history` parameter
-- @return true
local function apply_history(rb, history, start)
  
  for i = start, #history do 
    local target = history[i]
    if target.weight > 0 then
      assert(rb:addHost(target.name, target.port, target.weight))
    else
      assert(rb:removeHost(target.name, target.port))
    end
    rb.__targets_history[i] = {
      name = target.name,
      port = target.port,
      weight = target.weight,
      order = target.order,
    }
  end
  
  return true
end

-- looks up a balancer for the target.
-- @param target the table with the target details
-- @return balancer if found, or `false` if not found, or nil+error on error
local get_balancer = function(target)
  -- NOTE: only called upon first lookup, so `cache_only` limitations do not apply here
  local hostname = target.upstream.host
  
  -- first go and find the upstream object, from cache or the db
  local upstream, err = get_upstream(hostname)
  if err then
    return nil, err  -- there was an error
  elseif upstream == false then
    return false     -- no upstream by this name
  end
  
  -- we've got the upstream, now fetch its targets, from cache or the db
  local targets_history, err = cache.get_or_set(cache.targets_key(upstream.id), 
    function() return load_targets_into_memory(upstream.id) end)

  if err then
    return nil, err
  elseif #targets_history == 0 then 
    -- 'no targets' equals 'no upstream', so exit as well
    return nil, "no targets defined for upstream '"..hostname.."'"
  end

  local balancer = balancers[upstream.name] -- always exists, created upon fetching upstream
  
  -- check history state
  local __size = #balancer.__targets_history
  local size = #targets_history
  if __size ~= size or 
    balancer.__targets_history[__size].order ~= targets_history[size].order then
    -- last entries in history don't match, so we must do some updates.
    
    -- compare balancer history with db-loaded history
    local last_equal_index = 0  -- last index where history is the same
    for i, entry in ipairs(balancer.__targets_history) do
      if entry.order ~= (targets_history[i] or empty).order then
        last_equal_index = i - 1
        break
      end
    end

    if last_equal_index == __size then
      -- history is the same, so we only need to add new entries
      apply_history(balancer, targets_history, last_equal_index + 1)
    else
      -- history not the same.
      -- TODO: ideally we would undo the last ones until we're equal again
      -- and can replay changes, but not supported by ring-balancer yet.
      -- for now; create a new balancer from scratch
      local balancer, err = ring_balancer.new({
          wheelsize = upstream.slots,
          order = upstream.orderlist,
          dns = dns_client,
        })
      if not balancer then return balancer, err end
      balancers[upstream.name] = balancer  -- overwrite our existing one
      
      apply_history(balancer, targets_history, 1)
    end
  end
  
  return balancer
end


--===========================================================
-- Main entry point when resolving
--===========================================================

-- Resolves the target structure in-place (fields `ip` and `port`).
--
-- If the hostname matches an 'upstream' pool, then it must be balanced in that 
-- pool, in this case any port number provided will be ignored, as the pool provides it.
--
-- @param target the data structure as defined in `core.access.before` where it is created
-- @return true on success, nil+error otherwise
local function execute(target)
  local upstream = target.upstream
  
  if target.type ~= "name" then
    -- it's an ip address (v4 or v6), so nothing we can do...
    target.ip = upstream.host
    target.port = upstream.port or 80
    return true
  end
  
  -- when tries == 0 it runs before the `balancer` context (in the `access` context),
  -- when tries >= 2 then it performs a retry in the `balancer` context
  local dns_cache_only = target.tries ~= 0
  local balancer
  if dns_cache_only then
    -- retry, so balancer is already set if there was one
    balancer = target.balancer
  else
    local err
    -- first try, so try and find a matching balancer/upstream object
    balancer, err = get_balancer(target)
    if err then -- check on err, `nil` without `err` means we do dns resolution
      return nil, err
    end

    -- store for retries
    target.balancer = balancer
  end
  
  if balancer then
    -- have to invoke the ring-balancer
    local hashValue = nil  -- TODO: implement, nil does simple round-robin
    
    local ip, port, hostname = balancer:getPeer(hashValue, dns_cache_only)
    if not ip then 
      return ip, port
    end
    target.ip = ip
    target.port = port
    target.hostname = hostname
    return true
  else
    -- have to do a regular DNS lookup
    local ip, port = toip(upstream.host, upstream.port, dns_cache_only)
    if not ip then
      return nil, port
    end
    target.ip = ip
    target.port = port
    return true
  end
end

return { 
  execute = execute,
  _load_upstreams_dict_into_memory = load_upstreams_dict_into_memory,  -- exported for test purposes
  _load_upstream_into_memory = load_upstream_into_memory,  -- exported for test purposes
  _load_targets_into_memory = load_targets_into_memory,      -- exported for test purposes
}