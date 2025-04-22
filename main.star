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
    if "plugins" not in clean_args:
        output = ethereum.run(plan, clean_args)
        return output

    # Remove plugins key
    ethereum_args = {}
    for key in clean_args:
        if key != "plugins":
            ethereum_args[key] = clean_args[key]

    plugins = args.get("plugins", {})

    if "chainlink" in plugins:
        output = chainlink.run(plan, ethereum_args)
    else:
        output = ethereum.run(plan, ethereum_args)

    if "uniswap" in plugins:
        backend_url = plugins["uniswap"]["backend_url"]
        output = uniswap.run(plan, ethereum_args, backend_url)

    return output