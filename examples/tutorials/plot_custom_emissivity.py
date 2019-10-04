"""
Computing a camera image with custom emissivity
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

This tutorial defines an emissivity that varies in space and computes the signal received by a camera using
this emissivity.
"""

###############################################################################
# We start by loading a built-in `tofu` configuration and define a 2D camera.

import numpy as np
import tofu as tf

configB2 = tf.geom.utils.create_config("B2")

cam2d = tf.geom.utils.create_CamLOS2D(
    config=configB2,
    P=[3.4, 0, 0],
    N12=100,
    F=0.1,
    D12=0.1,
    angs=[np.pi, 0, 0],
    Name="",
    Exp="",
    Diag="",
)

###############################################################################
# Now, we define an emissivity function that depends on r and z coordinates.
# We can plot its profile in a section.
import matplotlib.pyplot as plt


def emissivity(pts, t=None, vect=None):
    """Custom emissivity as a function of geometry.


    :param pts: ndarray of shape (3, n_points) (each column is a xyz coordinate)
    :param t: optional, time parameter to add a time dependency to the emissivity function
    :param vect:
    :return:
        - emissivity - array holding the emissivity for each point in the input grid
    """
    r, z = np.hypot(pts[0, :], pts[1, :]), pts[2, :]
    e = np.exp(-(r - 2.4) ** 2 / 0.2 ** 2 - z ** 2 / 0.2 ** 2)
    if t is not None:
        e = np.cos(np.atleast_1d(t))[:, None] * e[None, :]
    return e


y = np.linspace(2, 3, num=90)
z = np.linspace(-0.5, 0.5, num=100)
Y, Z = np.meshgrid(y, z)
X = np.zeros_like(Y)
pts = np.c_[X.ravel(), Y.ravel(), Z.ravel()].T
emissivity_vals = emissivity(pts)
emissivity_vals = emissivity_vals.reshape(X.shape)

fig, ax = plt.subplots()
ax.pcolormesh(Y, Z, emissivity_vals)
ax.set_xlabel('y')
ax.set_ylabel('z')
plt.show()

###############################################################################
# Finally, we compute an image using the 2D camera and this emissivity. We use the
# `plot=True` flag to obtain a graphical output.

time_vector = np.linspace(0, 2 * np.pi, num=100)

sig, units = cam2d.calc_signal(emissivity,
                               resMode='rel', plot=False,
                               t=time_vector)
sig.plot()