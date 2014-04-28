part of angular.core.dom_internal;

abstract class ComponentFactory {
  FactoryFn call(dom.Node node, DirectiveRef ref);

  static async.Future<ViewFactory> _viewFuture(
        Component component, ViewCache viewCache, DirectiveMap directives) {
    if (component.template != null) {
      return new async.Future.value(viewCache.fromHtml(component.template, directives));
    }
    if (component.templateUrl != null) {
      return viewCache.fromUrl(component.templateUrl, directives);
    }
    return null;
  }

  static void _setupOnShadowDomAttach(controller, TemplateLoader templateLoader,
                                      Scope shadowScope) {
    if (controller is ShadowRootAware) {
      templateLoader.template.then((shadowDom) {
        if (!shadowScope.isAttached) return;
        (controller as ShadowRootAware).onShadowRoot(shadowDom);
      });
    }
  }
}

@Injectable()
class ShadowDomComponentFactory implements ComponentFactory {
  final Expando _expando;

  ShadowDomComponentFactory(this._expando);

  final Map<_ComponentAssetKey, async.Future<dom.StyleElement>> _styleElementCache = {};

  FactoryFn call(dom.Node node, DirectiveRef ref) {
    return (Injector injector) {
        var component = ref.annotation as Component;
        Scope scope = injector.get(Scope);
        ViewCache viewCache = injector.get(ViewCache);
        Http http = injector.get(Http);
        TemplateCache templateCache = injector.get(TemplateCache);
        DirectiveMap directives = injector.get(DirectiveMap);
        NgBaseCss baseCss = injector.get(NgBaseCss);
        // This is a bit of a hack since we are returning different type then we are.
        var componentFactory = new _ComponentFactory(node,
            ref.type,
            component,
            injector.get(dom.NodeTreeSanitizer),
            injector.get(WebPlatform),
            injector.get(ComponentCssRewriter),
            _expando,
            baseCss,
            _styleElementCache);
        var controller = componentFactory.call(injector, scope, viewCache, http, templateCache,
            directives);

        componentFactory.shadowScope.context[component.publishAs] = controller;
        return controller;
      };
  }
}


/**
 * ComponentFactory is responsible for setting up components. This includes
 * the shadowDom, fetching template, importing styles, setting up attribute
 * mappings, publishing the controller, and compiling and caching the template.
 */
class _ComponentFactory implements Function {

  final dom.Element element;
  final Type type;
  final Component component;
  final dom.NodeTreeSanitizer treeSanitizer;
  final Expando _expando;
  final NgBaseCss _baseCss;
  final Map<_ComponentAssetKey, async.Future<dom.StyleElement>>
      _styleElementCache;
  final ComponentCssRewriter componentCssRewriter;
  final WebPlatform platform;

  dom.ShadowRoot shadowDom;
  Scope shadowScope;
  Injector shadowInjector;
  var controller;

  _ComponentFactory(this.element, this.type, this.component, this.treeSanitizer,
                    this.platform, this.componentCssRewriter, this._expando,
                    this._baseCss, this._styleElementCache);

  dynamic call(Injector injector, Scope scope,
               ViewCache viewCache, Http http, TemplateCache templateCache,
               DirectiveMap directives) {
    shadowDom = element.createShadowRoot()
      ..applyAuthorStyles = component.applyAuthorStyles
      ..resetStyleInheritance = component.resetStyleInheritance;

    shadowScope = scope.createChild({}); // Isolate
    // TODO(pavelgj): fetching CSS with Http is mainly an attempt to
    // work around an unfiled Chrome bug when reloading same CSS breaks
    // styles all over the page. We shouldn't be doing browsers work,
    // so change back to using @import once Chrome bug is fixed or a
    // better work around is found.
    Iterable<async.Future<dom.StyleElement>> cssFutures;
    var cssUrls = []..addAll(_baseCss.urls)..addAll(component.cssUrls);
    var tag = element.tagName.toLowerCase();
    if (cssUrls.isNotEmpty) {
      cssFutures = cssUrls.map((cssUrl) => _styleElementCache.putIfAbsent(
          new _ComponentAssetKey(tag, cssUrl), () =>
        http.get(cssUrl, cache: templateCache)
          .then((resp) => resp.responseText,
            onError: (e) => '/*\n$e\n*/\n')
          .then((String css) {

            // Shim CSS if required
            if (platform.cssShimRequired) {
              css = platform.shimCss(css, selector: tag, cssUrl: cssUrl);
            }

            // If a css rewriter is installed, run the css through a rewriter
            var styleElement = new dom.StyleElement()
                ..appendText(componentCssRewriter(css, selector: tag,
                    cssUrl: cssUrl));

            // ensure there are no invalid tags or modifications
            treeSanitizer.sanitizeTree(styleElement);

            // If the css shim is required, it means that scoping does not
            // work, and adding the style to the head of the document is
            // preferrable.
            if (platform.cssShimRequired) {
              dom.document.head.append(styleElement);
            }

            return styleElement;
          })
      )).toList();
    } else {
      cssFutures = [new async.Future.value(null)];
    }

    var platformViewCache = new PlatformViewCache(viewCache, tag, platform);

    var viewFuture = ComponentFactory._viewFuture(component, platformViewCache,
        directives);

    TemplateLoader templateLoader = new TemplateLoader(
        async.Future.wait(cssFutures).then((Iterable<dom.StyleElement> cssList) {
          // This prevents style duplication by only adding css to the shadow
          // root if there is a native implementation of shadow dom.
          if (!platform.cssShimRequired) {
            cssList.where((styleElement) => styleElement != null)
              .forEach((styleElement) {
                shadowDom.append(styleElement.clone(true));
              });
          }
          if (viewFuture != null) {
            return viewFuture.then((ViewFactory viewFactory) {
              return (!shadowScope.isAttached) ?
                shadowDom :
                attachViewToShadowDom(viewFactory);
            });
          }
          return shadowDom;
        }));
    controller = createShadowInjector(injector, templateLoader).get(type);
    ComponentFactory._setupOnShadowDomAttach(controller, templateLoader, shadowScope);
    return controller;
  }

  dom.ShadowRoot attachViewToShadowDom(ViewFactory viewFactory) {
    var view = viewFactory(shadowInjector);
    shadowDom.nodes.addAll(view.nodes);
    return shadowDom;
  }

  Injector createShadowInjector(injector, TemplateLoader templateLoader) {
    var probe;
    var shadowModule = new Module()
      ..bind(type)
      ..bind(NgElement)
      ..bind(EventHandler, toImplementation: ShadowRootEventHandler)
      ..bind(Scope, toValue: shadowScope)
      ..bind(TemplateLoader, toValue: templateLoader)
      ..bind(dom.ShadowRoot, toValue: shadowDom)
      ..bind(ElementProbe, toFactory: (_) => probe);
    shadowInjector = injector.createChild([shadowModule], name: SHADOW_DOM_INJECTOR_NAME);
    probe = _expando[shadowDom] = new ElementProbe(
        injector.get(ElementProbe), shadowDom, shadowInjector, shadowScope);
    return shadowInjector;
  }
}

class _ComponentAssetKey {
  final String tag;
  final String assetUrl;

  final String _key;

  _ComponentAssetKey(String tag, String assetUrl)
      : _key = "$tag|$assetUrl",
        this.tag = tag,
        this.assetUrl = assetUrl;

  @override
  String toString() => _key;

  @override
  int get hashCode => _key.hashCode;

  bool operator ==(key) =>
      key is _ComponentAssetKey
      && tag == key.tag
      && assetUrl == key.assetUrl;
}

@Injectable()
class ComponentCssRewriter {
  String call(String css, { String selector, String cssUrl} ) {
    return css;
  }
}