# LaTeX in Nota

Press ⇧⌘P to cycle editor → split → reading, or ⌥⇧⌘P to jump straight to reading.

## Inline maths

Inline formulas sit in the sentence: the quadratic roots are $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$, Euler's identity is $e^{i\pi} + 1 = 0$, and Pythagoras says $a^2 + b^2 = c^2$.

Subscripts and superscripts stack on one atom: $x_i^2$, $a_{n+1}$, $e^{-x^2/2}$, and $x'$ is a prime.

Dollars that are not maths stay prose: this costs $5 and $10 more. A dollar in code is literal too: `$HOME` and `$x$`. An escaped dollar \$ is just a dollar.

## Display maths

A `$$` paragraph stands on its own, centred, and is its own block for click-to-source:

$$
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
$$

A fenced block with the `math` info string does the same:

```math
\int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
```

Limits, products and unions in display style:

$$
\lim_{x \to 0} \frac{\sin x}{x} = 1 \qquad \prod_{k=1}^{n} k = n! \qquad \bigcup_{i \in I} A_i
$$

## Fractions, roots and delimiters

$$
\left( \frac{a}{b} + \frac{c}{d} \right)^{2} = \frac{(ad + bc)^2}{b^2 d^2}
$$

$$
\sqrt{x^2 + y^2} \qquad \sqrt[3]{27} = 3 \qquad \binom{n}{k} = \frac{n!}{k!\,(n-k)!}
$$

$$
\left[ \frac{1}{2} \right] \quad \left\{ x \mid x > 0 \right\} \quad \left| \frac{p}{q} \right| \quad \left\langle u, v \right\rangle \quad \left\lfloor \frac{n}{2} \right\rfloor
$$

## Greek, sets and symbols

Greek: $\alpha, \beta, \gamma, \delta, \varepsilon, \theta, \lambda, \mu, \pi, \sigma, \phi, \omega$ and $\Gamma, \Delta, \Theta, \Lambda, \Pi, \Sigma, \Phi, \Omega$.

Sets and logic: $\forall \varepsilon > 0\ \exists \delta > 0$, $\mathbb{N} \subset \mathbb{Z} \subset \mathbb{Q} \subset \mathbb{R} \subset \mathbb{C}$, $x \in A \cup B$, $A \cap B = \emptyset$.

Relations and arrows: $a \leq b$, $a \neq b$, $a \approx b$, $a \equiv b$, $f: X \to Y$, $P \Rightarrow Q$, $P \Leftrightarrow Q$, $\partial f / \partial x$, $\nabla \cdot \vec{F}$.

Functions and accents: $\sin^2 \theta + \cos^2 \theta = 1$, $\log_2 8 = 3$, $\hat{x}$, $\bar{y}$, $\tilde{z}$, $\dot{q}$, $\vec{v}$.

Faces and text: $\mathbf{A}\mathbf{x} = \mathbf{b}$, $\mathrm{d}x$, $\mathcal{L}(f)$, $\text{for all } n \geq 1$, $\operatorname{tr}(M)$.

Spacing: $a\,b\;c\quad d\qquad e$ and $\ldots$, $\cdots$, $\infty$, $\hbar$, $\ell$.

## What happens when it goes wrong

An unknown command draws itself raw inside the formula rather than breaking it: $\alpha + \unknowncmd{x} + \beta$.

TeX that cannot be parsed at all falls back to a code span: ${x$ and $\left( x$ and $\frac{a}$.

An unclosed dollar $ on a line is left alone, and a formula never spans lines: $a
+ b$ stays text.

## Physics and statistics, for fun

$$
E = mc^2 \qquad F = G \frac{m_1 m_2}{r^2} \qquad i\hbar \frac{\partial}{\partial t} \Psi = \hat{H} \Psi
$$

$$
f(x) = \frac{1}{\sigma \sqrt{2\pi}} \, e^{-\frac{(x - \mu)^2}{2\sigma^2}}
$$

$$
\bar{x} = \frac{1}{n} \sum_{i=1}^{n} x_i \qquad s^2 = \frac{1}{n-1} \sum_{i=1}^{n} (x_i - \bar{x})^2
$$
