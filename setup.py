from setuptools import setup

setup(
    name="nep",
    version="0.1.0",
    description="A deliberately tiny coding agent for self-hosted models — runs on system Python, no venv required.",
    py_modules=["nep"],            # tells setuptools to package the single .py file
    python_requires=">=3.9",
    install_requires=[
        "openai",                  # the only runtime dep, per the file's docstring
        "httpx<0.28",              # openai<1.55 passes proxies=; httpx>=0.28 removed it
    ],
    entry_points={
        "console_scripts": [
            "nep=nep:main",        # creates a `nep` command that calls nep.main()
        ],
    },
)
