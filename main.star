def run(plan, args):

    env = args["env"]
    # Conditional imports
    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))
    chainlink = import_module("github.com/LZeroAnalytics/chainlink-package@{}/main.star".format(env))
    uniswap = import_module("github.com/LZeroAnalytics/uniswap-package@{}/main.star".format(env))

    clean_args = {}
    for key in args:
        if key != "env":
            clean_args[key] = args[key]

    output = struct()

    # Remove plugins key
    ethereum_args = {}
    for key in clean_args:
        if key != "plugins":
            ethereum_args[key] = clean_args[key]

    plugins = args.get("plugins", {})

    if plugins != None:
        if "chainlink" in plugins:
            output = chainlink.run(plan, ethereum_args)
        if "uniswap" in plugins:
            uniswap_config = plugins["uniswap"] 
            backend_url = uniswap_config.get("backend_url")
            rpc_url = uniswap_config.get("rpc_url")
            output = uniswap.run(plan, ethereum_args, rpc_url, backend_url)
            
    if not "plugins" in args or not args["plugins"]:
        output = ethereum.run(plan, ethereum_args)

    return output