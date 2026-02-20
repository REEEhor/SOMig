///
/// `SymbolId` is a unique identifier that `SymbolsManager` uses to identify symbols.
///
/// A symbol in SOM refers to a string that is deduplicated (interned).
/// There is only a single instance of a string in the entire runtime per (unique string).
///
/// This enables for example fast comparisons between symbols.
///
/// In SOM, it has the syntax `#some_symbol` or `#"some_symbol"` (in quotes)
/// and it can also be used to specify methods by their name, like: `#some:keyword:method:`.
///
/// In SOMig (this virtual machine), symbols are also used for representing identifiers
/// - which means not only names of methods, but also the names of classes, local variables...
///
/// String literals (which are surrounded by the `'` character in the source code)
/// and SOM string objects are managed elsewhere.
/// In a similiar way as other virtual machine objects are.
///
pub const SymbolId = packed struct(u24) {
    ///
    /// Index into an array of symbols in `SymbolsManager`.
    ///
    /// A 24 bit index should be enough, it gives us 2^24 = ~16.8 million possible values.
    /// That should be enough for any application written in SOM.
    ///
    /// Even if every line in a SOM source code contained 16 symbols, there could be a codebase with over one million rows.
    /// Also, the symbols would have to be *unique*, which increases the options even more.
    ///
    /// On the other hand, having only 24 bit identifier is nice for storing that in instructions.
    /// For example, the `send_message` instruction can be 32 bits in total (1 byte tag, rest `SymbolId`).
    /// Which is actually important, since that is probably the most common instruction in the whole SOM.
    ///
    idx: IdRepr,
    pub const IdRepr = u24;

    pub fn new(idx: IdRepr) SymbolId {
        return .{ .idx = idx };
    }
};
