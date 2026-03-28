# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = 'Terrain3D'
copyright = '2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors'
author = 'Cory Petkovsek, Roope Palmroos, and Contributors'
release = '1.1.0'

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

# TODO sphinx_tabs used in programming_languages.rst requires sphinx < 9. 
# Migrate to sphinx-design and sphinx 9+, then we can use tabs in markdown
extensions = ['myst_parser', 'sphinx_rtd_dark_mode', 'sphinx_tabs.tabs']

myst_heading_anchors = 3
default_dark_mode = False

templates_path = ['_templates']
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = 'sphinx_rtd_theme'
html_static_path = ['_static']
html_css_files = ['theme_overrides.css']