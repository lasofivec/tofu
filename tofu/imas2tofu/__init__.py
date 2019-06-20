# -*- coding: utf-8 -*-
#! /usr/bin/python
"""
The imas-compatibility module of tofu

"""
import warnings

try:
    import imas
    try:
        from tofu.imas2tofu._core import *
    except Exception:
        from ._core import *
    del imas, warnings
except Exception as err:
    msg = str(err)
    msg += "\n\nIMAS python API issue\n"
    msg += "imas could not be imported into tofu ('import imas' failed):\n"
    msg += "  - it may not be installed (optional dependency)\n"
    msg += "  - or you not have loaded the good working environment\n\n"
    msg += "    => the optional sub-package tofu.imas2tofu is not usable\n"
    warnings.warn(msg)
    del msg, err

__all__ = ['MultiIDSLoader', 'load_Config', 'load_Plasma2D',
           'load_Cam', 'load_Data']
