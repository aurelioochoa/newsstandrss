// Settings > NewsstandRSS: the feed list (add, rename, change address, delete) and appearance options.
// Feed edits are written to the shared feed list; SpringBoard then creates, renames or removes the magazines.

#import <Preferences/PSListController.h>
#import <Preferences/PSListItemsController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import "NRSSFeedAdder.h"
#import "NRSSShared.h"

@interface PSSpecifier (NRSSChoices)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles shortTitles:(NSArray *)shortTitles;
@end

@interface PSListController (NRSSPrivate)
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface NRSSSettingsController : PSListController <UIAlertViewDelegate>
@end

@interface NRSSFeedEditor : PSListController <UIActionSheetDelegate>
@end

@interface NRSSCatalogController : PSListController <UIAlertViewDelegate>
@end

static PSSpecifier *NRSSGroup(NSString *title, NSString *footer) {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:title];
    if (footer)
        [group setProperty:footer forKey:@"footerText"];
    return group;
}

static PSSpecifier *NRSSValue(NSString *name, NSString *key, PSCellType type, id target, id fallback) {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:target set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:) detail:nil cell:type edit:nil];
    [specifier setProperty:key forKey:@"key"];
    if (fallback)
        [specifier setProperty:fallback forKey:@"default"];
    return specifier;
}

static PSSpecifier *NRSSChoice(NSString *name, NSString *key, NSArray *values, NSArray *titles, id target, id fallback) {
    PSSpecifier *specifier = NRSSValue(name, key, PSLinkListCell, target, fallback);
    [specifier setValues:values titles:titles shortTitles:titles];
    specifier.detailControllerClass = [PSListItemsController class];
    return specifier;
}

static PSSpecifier *NRSSButton(NSString *name, id target, SEL action) {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:target set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    specifier->action = action;
    return specifier;
}

static void NRSSShowAlert(NSString *title, NSString *message) {
    [[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

#pragma mark - Main page

@implementation NRSSSettingsController {
    UIAlertView *_progress;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:NRSSGroup(NRSSLocalized(@"Feeds", @"Fuentes"),
                                   NRSSLocalized(@"Each feed is a magazine in Newsstand. You can also add feeds with the + button there and delete them by holding a magazine.",
                                                 @"Cada fuente es una revista en Quiosco. También puedes añadirlas con el botón + de allí y borrarlas manteniendo pulsada una revista."))];
        NSArray *feeds = [NRSSLoadFeeds() sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a objectForKey:@"title"] localizedCaseInsensitiveCompare:[b objectForKey:@"title"]];
        }];
        for (NSDictionary *feed in feeds) {
            PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:[feed objectForKey:@"title"] target:self set:nil get:nil
                                                               detail:[NRSSFeedEditor class] cell:PSLinkCell edit:nil];
            [link setProperty:[feed objectForKey:@"id"] forKey:@"feedID"];
            [items addObject:link];
        }
        [items addObject:NRSSButton(NRSSLocalized(@"Add Feed…", @"Añadir fuente…"), self, @selector(promptForFeed))];
        [items addObject:[PSSpecifier preferenceSpecifierNamed:NRSSLocalized(@"Suggested Feeds", @"Fuentes sugeridas") target:self set:nil get:nil
                                                        detail:[NRSSCatalogController class] cell:PSLinkCell edit:nil]];

        [items addObject:NRSSGroup(NRSSLocalized(@"Newsstand", @"Quiosco"), nil)];
        [items addObject:NRSSChoice(NRSSLocalized(@"Add Button", @"Botón para añadir"), NRSSButtonPlacementKey,
                                    @[@"beside", @"replace", @"hidden"],
                                    @[NRSSLocalized(@"Next to Store", @"Junto a Store"), NRSSLocalized(@"Replace Store", @"Reemplazar Store"),
                                      NRSSLocalized(@"Hidden", @"Oculto")], self, @"beside")];

        [items addObject:NRSSGroup(NRSSLocalized(@"Covers", @"Portadas"),
                                   NRSSLocalized(@"Covers show the latest headlines and are refreshed in the background while the phone has a connection.",
                                                 @"Las portadas muestran los últimos titulares y se actualizan en segundo plano cuando hay conexión."))];
        [items addObject:NRSSValue(NRSSLocalized(@"Article Photo", @"Foto del artículo"), NRSSCoverPhotosKey, PSSwitchCell, self, @YES)];
        [items addObject:NRSSChoice(NRSSLocalized(@"Headlines", @"Titulares"), NRSSCoverHeadlinesKey, @[@1, @3],
                                    @[NRSSLocalized(@"Latest only", @"Solo el último"), NRSSLocalized(@"Latest three", @"Los tres últimos")], self, @3)];
        [items addObject:NRSSChoice(NRSSLocalized(@"Update Covers", @"Actualizar portadas"), NRSSCoverRefreshHoursKey, @[@0, @1, @3, @6, @12],
                                    @[NRSSLocalized(@"Never", @"Nunca"), NRSSLocalized(@"Every hour", @"Cada hora"),
                                      NRSSLocalized(@"Every 3 hours", @"Cada 3 horas"), NRSSLocalized(@"Every 6 hours", @"Cada 6 horas"),
                                      NRSSLocalized(@"Every 12 hours", @"Cada 12 horas")], self, @6)];
        [items addObject:NRSSButton(NRSSLocalized(@"Update All Covers Now", @"Actualizar todas las portadas ahora"), self, @selector(refreshCovers))];

        [items addObject:NRSSGroup(NRSSLocalized(@"Reader", @"Lector"), nil)];
        [items addObject:NRSSChoice(NRSSLocalized(@"Text Size", @"Tamaño del texto"), NRSSReaderTextSizeKey, @[@15, @17, @20, @23],
                                    @[NRSSLocalized(@"Small", @"Pequeño"), NRSSLocalized(@"Medium", @"Mediano"),
                                      NRSSLocalized(@"Large", @"Grande"), NRSSLocalized(@"Extra large", @"Muy grande")], self, @17)];
        [items addObject:NRSSChoice(NRSSLocalized(@"Theme", @"Tema"), NRSSReaderThemeKey, @[@"light", @"sepia", @"dark"],
                                    @[NRSSLocalized(@"Light", @"Claro"), NRSSLocalized(@"Sepia", @"Sepia"), NRSSLocalized(@"Dark", @"Oscuro")], self, @"sepia")];
        [items addObject:NRSSValue(NRSSLocalized(@"Thumbnails in List", @"Miniaturas en la lista"), NRSSListThumbnailsKey, PSSwitchCell, self, @YES)];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = @"NewsstandRSS";
    [self reloadSpecifiers];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return NRSSPreference([specifier propertyForKey:@"key"], [specifier propertyForKey:@"default"]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionaryWithContentsOfFile:NRSSPreferencesPath] ?: [NSMutableDictionary dictionary];
    [preferences setObject:value forKey:[specifier propertyForKey:@"key"]];
    if (![preferences writeToFile:NRSSPreferencesPath atomically:YES]) {
        NRSSShowAlert(@"NewsstandRSS", NRSSLocalized(@"The setting could not be saved.", @"No se pudo guardar el ajuste."));
        return;
    }
    notify_post(NRSSPreferencesChangedNotification);
}

- (void)refreshCovers {
    notify_post(NRSSRefreshCoversNotification);
    NRSSShowAlert(NRSSLocalized(@"Updating Covers", @"Actualizando portadas"),
                  NRSSLocalized(@"The magazines will show the new headlines in a moment.",
                                @"Las revistas mostrarán los nuevos titulares en un momento."));
}

- (void)promptForFeed {
    UIAlertView *prompt = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Add RSS Feed", @"Añadir fuente RSS")
                                                     message:NRSSLocalized(@"Enter the address of a feed or of the website.",
                                                                           @"Escribe la dirección del feed o del sitio web.")
                                                    delegate:self cancelButtonTitle:NRSSLocalized(@"Cancel", @"Cancelar")
                                           otherButtonTitles:NRSSLocalized(@"Add", @"Añadir"), nil];
    prompt.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [prompt textFieldAtIndex:0];
    field.placeholder = @"example.com/feed";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [prompt show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)index {
    if (alertView.alertViewStyle != UIAlertViewStylePlainTextInput || index != alertView.firstOtherButtonIndex)
        return;
    _progress = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Adding Feed…", @"Añadiendo fuente…")
                                           message:nil delegate:nil cancelButtonTitle:nil otherButtonTitles:nil];
    [_progress show];
    [NRSSFeedAdder addFeedFromString:[alertView textFieldAtIndex:0].text completion:^(NSString *feedID, NSString *errorMessage) {
        [_progress dismissWithClickedButtonIndex:0 animated:YES];
        _progress = nil;
        if (!feedID) {
            NRSSShowAlert(NRSSLocalized(@"Couldn't Add Feed", @"No se pudo añadir la fuente"), errorMessage);
            return;
        }
        NRSSPostFeedsChanged();
        [self reloadSpecifiers];
    }];
}

@end

#pragma mark - One feed

@implementation NRSSFeedEditor {
    NSString *_feedID;
    NSMutableDictionary *_draft;
}

- (void)loadDraft {
    _feedID = [self.specifier propertyForKey:@"feedID"];
    _draft = [NRSSFeedWithID(_feedID) mutableCopy];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self loadDraft];
        NSMutableArray *items = [NSMutableArray array];
        if (!_draft) {
            [items addObject:NRSSGroup(nil, NRSSLocalized(@"This feed was removed.", @"Esta fuente fue eliminada."))];
            _specifiers = items;
            return _specifiers;
        }
        [items addObject:NRSSGroup(NRSSLocalized(@"Name", @"Nombre"), nil)];
        PSSpecifier *name = NRSSValue(NRSSLocalized(@"Name", @"Nombre"), @"title", PSEditTextCell, self, nil);
        [items addObject:name];
        [items addObject:NRSSGroup(NRSSLocalized(@"Feed Address", @"Dirección del feed"),
                                   [_draft objectForKey:@"site"] && [[_draft objectForKey:@"site"] length]
                                       ? [NSString stringWithFormat:NRSSLocalized(@"Website: %@", @"Sitio web: %@"), [_draft objectForKey:@"site"]]
                                       : nil)];
        PSSpecifier *address = NRSSValue(NRSSLocalized(@"Address", @"Dirección"), @"url", PSEditTextCell, self, nil);
        [address setProperty:@YES forKey:@"noAutoCorrect"];
        [items addObject:address];
        [items addObject:NRSSGroup(nil, nil)];
        [items addObject:NRSSButton(NRSSLocalized(@"Save Changes", @"Guardar cambios"), self, @selector(save))];
        [items addObject:NRSSGroup(nil, nil)];
        [items addObject:NRSSButton(NRSSLocalized(@"Delete Feed", @"Eliminar fuente"), self, @selector(confirmDelete))];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = [_draft objectForKey:@"title"] ?: [self.specifier name];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return [_draft objectForKey:[specifier propertyForKey:@"key"]];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [_draft setObject:value ?: @"" forKey:[specifier propertyForKey:@"key"]];
}

- (void)save {
    [self.view endEditing:YES];
    NSURL *url = NRSSURLFromUserInput([_draft objectForKey:@"url"]);
    if (!url) {
        NRSSShowAlert(NRSSLocalized(@"Invalid Address", @"Dirección no válida"),
                      NRSSLocalized(@"Enter an http or https address.", @"Escribe una dirección http o https."));
        return;
    }
    NSDictionary *existing = NRSSFeedWithURL(url.absoluteString);
    if (existing && ![[existing objectForKey:@"id"] isEqualToString:_feedID]) {
        NRSSShowAlert(NRSSLocalized(@"Already Added", @"Ya añadida"),
                      [NSString stringWithFormat:NRSSLocalized(@"“%@” uses that address.", @"“%@” ya usa esa dirección."),
                       [existing objectForKey:@"title"]]);
        return;
    }
    NSDictionary *saved = NRSSFeedWithID(_feedID);
    if (!saved) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    NSMutableDictionary *record = [saved mutableCopy];
    [record setObject:[NRSSFeedAdder displayNameFromString:[_draft objectForKey:@"title"] fallback:url.host] forKey:@"title"];
    if (![[record objectForKey:@"url"] isEqualToString:url.absoluteString]) {
        [record setObject:url.absoluteString forKey:@"url"];
        // The cached document belongs to the old address.
        [[NSFileManager defaultManager] removeItemAtPath:NRSSCachePathForFeedID(_feedID, @"xml") error:NULL];
    }
    if (!NRSSSaveFeed(record)) {
        NRSSShowAlert(@"NewsstandRSS", NRSSLocalized(@"The feed could not be saved.", @"No se pudo guardar la fuente."));
        return;
    }
    NRSSPostFeedsChanged();
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)confirmDelete {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:
                                NRSSLocalized(@"“%@” will be removed from Newsstand.", @"“%@” se quitará de Quiosco."),
                                [_draft objectForKey:@"title"]]
                                                       delegate:self cancelButtonTitle:NRSSLocalized(@"Cancel", @"Cancelar")
                                         destructiveButtonTitle:NRSSLocalized(@"Delete Feed", @"Eliminar fuente") otherButtonTitles:nil];
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index != sheet.destructiveButtonIndex)
        return;
    NRSSRemoveFeedRecord(_feedID);
    NRSSPostFeedsChanged();
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Suggested feeds

@implementation NRSSCatalogController {
    NSDictionary *_catalog;
    UIAlertView *_progress;
    NSString *_offeredCountry;
}

static BOOL NRSSSpanishInterface(void) {
    return [NRSSLocalized(@"en", @"es") isEqualToString:@"es"];
}

- (NSArray *)countries {
    if (!_catalog)
        _catalog = [NSDictionary dictionaryWithContentsOfFile:NRSSCatalogPath];
    NSString *nameKey = NRSSSpanishInterface() ? @"es" : @"en";
    return [[_catalog objectForKey:@"countries"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a objectForKey:nameKey] localizedCaseInsensitiveCompare:[b objectForKey:nameKey]];
    }];
}

- (NSDictionary *)countryWithCode:(NSString *)code {
    for (NSDictionary *country in self.countries)
        if ([[country objectForKey:@"code"] isEqualToString:code])
            return country;
    return nil;
}

- (NSString *)nameOfCountry:(NSDictionary *)country {
    return [country objectForKey:NRSSSpanishInterface() ? @"es" : @"en"];
}

- (PSSpecifier *)switchForFeed:(NSDictionary *)feed {
    PSSpecifier *specifier = NRSSValue([feed objectForKey:@"title"], @"catalog", PSSwitchCell, self, nil);
    [specifier setProperty:[feed objectForKey:@"url"] forKey:@"feedURL"];
    return specifier;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:NRSSGroup(NRSSLocalized(@"Your Country", @"Tu país"),
                                   NRSSLocalized(@"Choose your country to add its most relevant news sources at once. Each one can be turned off below.",
                                                 @"Elige tu país para añadir de una vez sus fuentes de noticias más relevantes. Puedes desactivar cualquiera abajo."))];
        NSMutableArray *codes = [NSMutableArray arrayWithObject:@"none"];
        NSMutableArray *names = [NSMutableArray arrayWithObject:NRSSLocalized(@"None", @"Ninguno")];
        for (NSDictionary *country in self.countries) {
            [codes addObject:[country objectForKey:@"code"]];
            [names addObject:[self nameOfCountry:country]];
        }
        [items addObject:NRSSChoice(NRSSLocalized(@"Country", @"País"), NRSSCountryKey, codes, names, self, @"none")];

        NSDictionary *country = [self countryWithCode:NRSSPreference(NRSSCountryKey, @"none")];
        if (country) {
            [items addObject:NRSSGroup([self nameOfCountry:country], nil)];
            for (NSDictionary *feed in [country objectForKey:@"feeds"])
                [items addObject:[self switchForFeed:feed]];
            [items addObject:NRSSButton(NRSSLocalized(@"Add All", @"Añadir todas"), self, @selector(addAllFromCountry))];
        }

        [items addObject:NRSSGroup(NRSSLocalized(@"General", @"Generales"),
                                   NRSSLocalized(@"International news, technology and science.", @"Noticias internacionales, tecnología y ciencia."))];
        for (NSDictionary *feed in [_catalog objectForKey:@"general"])
            [items addObject:[self switchForFeed:feed]];
        [items addObject:NRSSButton(NRSSLocalized(@"Add All", @"Añadir todas"), self, @selector(addAllGeneral))];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = NRSSLocalized(@"Suggested Feeds", @"Fuentes sugeridas");
    [self reloadSpecifiers];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *url = [specifier propertyForKey:@"feedURL"];
    if (url)
        return @(NRSSFeedWithURL(url) != nil);
    return NRSSPreference([specifier propertyForKey:@"key"], [specifier propertyForKey:@"default"]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *url = [specifier propertyForKey:@"feedURL"];
    if (url) {
        if ([value boolValue]) {
            [self addFeeds:@[@{@"url": url, @"title": [specifier name] ?: @""}]];
        } else {
            NSDictionary *feed;
            while ((feed = NRSSFeedWithURL(url)))
                NRSSRemoveFeedRecord([feed objectForKey:@"id"]);
            NRSSPostFeedsChanged();
        }
        return;
    }
    NSMutableDictionary *preferences = [NSMutableDictionary dictionaryWithContentsOfFile:NRSSPreferencesPath] ?: [NSMutableDictionary dictionary];
    [preferences setObject:value forKey:[specifier propertyForKey:@"key"]];
    [preferences writeToFile:NRSSPreferencesPath atomically:YES];
    [self reloadSpecifiers];
    NSDictionary *country = [self countryWithCode:value];
    if (!country)
        return;
    // Offer the whole set for the newly chosen country right away.
    _offeredCountry = value;
    UIAlertView *offer = [[UIAlertView alloc] initWithTitle:[self nameOfCountry:country]
                                                    message:[NSString stringWithFormat:NRSSLocalized(@"Add its %lu most relevant news sources to Newsstand?",
                                                                                                     @"¿Añadir a Quiosco sus %lu fuentes de noticias más relevantes?"),
                                                             (unsigned long)[[country objectForKey:@"feeds"] count]]
                                                   delegate:self cancelButtonTitle:NRSSLocalized(@"Not Now", @"Ahora no")
                                          otherButtonTitles:NRSSLocalized(@"Add", @"Añadir"), nil];
    [offer show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)index {
    if (index == alertView.firstOtherButtonIndex && _offeredCountry)
        [self addFeeds:[[self countryWithCode:_offeredCountry] objectForKey:@"feeds"]];
    _offeredCountry = nil;
}

- (void)addAllFromCountry {
    [self addFeeds:[[self countryWithCode:NRSSPreference(NRSSCountryKey, @"none")] objectForKey:@"feeds"]];
}

- (void)addAllGeneral {
    [self addFeeds:[_catalog objectForKey:@"general"]];
}

- (void)addFeeds:(NSArray *)entries {
    if (_progress || !entries.count)
        return;
    _progress = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Adding Feeds…", @"Añadiendo fuentes…")
                                           message:@" " delegate:nil cancelButtonTitle:nil otherButtonTitles:nil];
    [_progress show];
    [NRSSFeedAdder addFeedsFromStrings:entries progress:^(NSUInteger done, NSUInteger total) {
        _progress.message = [NSString stringWithFormat:NRSSLocalized(@"%lu of %lu", @"%lu de %lu"), (unsigned long)done, (unsigned long)total];
    } completion:^(NSUInteger added, NSArray *failedInputs) {
        [_progress dismissWithClickedButtonIndex:0 animated:YES];
        _progress = nil;
        if (added)
            NRSSPostFeedsChanged();
        [self reloadSpecifiers];
        if (failedInputs.count)
            NRSSShowAlert(NRSSLocalized(@"Some Feeds Were Not Added", @"Algunas fuentes no se añadieron"),
                          [NSString stringWithFormat:NRSSLocalized(@"%lu could not be reached right now. You can try them again later.",
                                                                   @"%lu no respondieron ahora. Puedes intentarlo más tarde."),
                           (unsigned long)failedInputs.count]);
    }];
}

@end
